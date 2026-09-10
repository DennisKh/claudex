defmodule Claudex.Tool do
  @moduledoc """
  Turns tagged functions into tools Claude can call.

  Add `use Claudex.Tool` to a module, then tag a function with `@tool`
  right above its definition. Claudex reads the function's `@doc` for the
  tool's description and its `@spec` for the argument types, and builds
  the JSON schema the Messages API expects:

      defmodule MyApp.Tools do
        use Claudex.Tool

        @doc "Adds two numbers and returns the sum. Use it for arithmetic rather than working it out."
        @tool true
        @spec add(number(), number()) :: number()
        def add(a, b), do: a + b
      end

      Claudex.Tool.list(MyApp.Tools)
      #=> [%{name: "add", description: "Adds two numbers and returns...", input_schema: %{...}}]

  `Claudex.Messages.create/2` takes the module directly as `tools:` and
  expands it for you.

  Your `@doc` and `@spec` are prompt text, not developer notes. They are the
  whole of what Claude knows about the tool: the `@doc` decides whether it
  reaches for the tool at all, and the argument descriptions decide what it
  passes. Write them for the model, and expect a terse one-liner to produce a
  tool that gets called at the wrong moment or with the wrong values.

  Pass a map instead of `true` for options:

    * `:args` - a description per argument, merged into the inferred schema
    * `:strict` - sets `strict: true` on the tool definition
    * `:args_schema` - use this JSON schema for the properties instead of
      inferring one from `@spec`. Takes full priority: when it's set, the
      `@spec` is never even inspected, so it's also the way out of a type
      Claudex can't map (see below), or when you need something a
      typespec can't express (an `enum`, say)

  Claude picks arguments from their descriptions, so an argument named
  `path` tells it less than one described as an absolute path. `:args` merges
  into the inferred schema rather than replacing it, so the types still come
  from the `@spec`:

      @doc "Read a UTF-8 text file and return its contents."
      @tool %{args: [path: "Absolute path, or relative to the project directory."]}
      @spec read_file(String.t()) :: String.t()
      def read_file(path), do: File.read!(path)

      # properties: %{"path" => %{type: "string", description: "Absolute path, ..."}}

  A key naming no argument raises at compile time, so renaming a parameter
  can't silently drop its description. Describe an underscored parameter by
  the name Claude sees: `_path` is published as `path`.

  `:args_schema` is the `properties` object, not the whole input schema —
  `required` still comes from which parameters have defaults:

      @doc "Fetches the current weather for a city."
      @tool %{
        args_schema: %{
          "city" => %{type: "string", description: "City and country, e.g. Lisbon, PT"},
          "unit" => %{type: "string", enum: ["celsius", "fahrenheit"]}
        }
      }
      @spec get_weather(String.t(), String.t()) :: String.t()
      def get_weather(city, unit \\ "celsius"), do: ...

      # input_schema: %{
      #   type: "object",
      #   properties: %{"city" => ..., "unit" => ...},
      #   required: ["city"],
      #   additionalProperties: false
      # }

  When a `tool_use` block comes back from Claude, `call/3` runs the matching
  function:

      Claudex.Tool.call(MyApp.Tools, "add", %{"a" => 1, "b" => 2})
      #=> {:ok, 3}

  `Claudex.ToolRunner` does this natively — it runs the tools Claude asks for
  and feeds the results back, so a whole tool conversation is one call.

  The `@doc` is what Claude reads to decide when to call a tool, so a `@tool`
  without one compiles with a warning and a placeholder description.

  A function with no `@spec` at all still registers, with unconstrained
  properties. Put the `@spec` above the function (or anywhere earlier in the
  module) and make sure its arity matches, or Claudex won't find it either.

  A defaulted argument makes two arities, and Claudex reads the widest one:
  `@spec add(number()) :: number()` alone won't match `def add(a, b \\ 0)`,
  and both properties come out unconstrained. Writing one `@spec` per arity
  is fine — the matching one is picked whichever order they're in.

  A struct type in a `@spec` — `Ticket.t()` for a plain `defstruct` with a
  `@type t`, or for an Ecto schema — expands into a nested object schema
  instead of an unconstrained one, recursively (an Ecto `embeds_one`/
  `embeds_many` field included; `belongs_to`/`has_many`/`has_one` are
  skipped, since they're not part of the data itself and expanding them
  risks recursing through a relationship graph). This only shapes the
  *schema* Claude sees — the argument your function actually receives is
  still the plain decoded JSON map (string keys), never cast into a real
  struct.

  A `@spec` type Claudex genuinely can't map — an unsupported typespec
  construct, or a `Mod.t()` that isn't a loaded struct or Ecto schema —
  raises `Claudex.Tool.SchemaError` at compile time. Fix the spec, or pass
  `:args_schema` to skip inference for that tool entirely. See
  `Claudex.Tool.Schema.StructExpansion` for exactly what's supported.
  """

  alias Claudex.Tool.{CallError, Dispatch, Schema, SchemaError}

  @tool_opts [:args, :args_schema, :strict]

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :registered_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :tool_dispatch_entries, accumulate: true)

      @on_definition {Claudex.Tool, :__on_definition__}
      @before_compile Claudex.Tool
    end
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), [Macro.t()], Macro.t(), Macro.t()) :: :ok
  def __on_definition__(env, kind, name, args, _guards, _body) do
    case Module.get_attribute(env.module, :tool) do
      nil ->
        :ok

      _tool_opts when kind != :def ->
        raise SchemaError, message: private_tool_message(name, args, kind)

      tool_opts ->
        register(env, name, args, tool_opts)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    tools =
      env.module |> Module.get_attribute(:registered_tools) |> Enum.reverse() |> Macro.escape()

    entries =
      env.module
      |> Module.get_attribute(:tool_dispatch_entries)
      |> Enum.reverse()
      |> Macro.escape()

    # Generated into someone else's module, so these carry the underscore
    # prefix that marks them as ours rather than risking a clash with a
    # function they meant to write. `Claudex.Tool.list/1` and
    # `Claudex.Tool.call/3` are the public way in; these stay out of the docs.
    quote do
      @doc false
      @spec __tools__() :: [map()]
      def __tools__, do: unquote(tools)

      @doc false
      @spec __call_tool__(String.t(), map()) :: {:ok, term()} | {:error, CallError.t()}
      def __call_tool__(name, args), do: Dispatch.call(__MODULE__, unquote(entries), name, args)
    end
  end

  @doc """
  Runs one of `module`'s tools by the name Claude used, with the input from its
  `tool_use` block.

      Claudex.Tool.call(MyApp.Tools, "add", %{"a" => 1, "b" => 2})
      #=> {:ok, 3}

  Arguments are matched to the function's parameters by name, so their order in
  the map doesn't matter, and a trailing optional parameter can be left out.

  A tool that fails returns `{:error, %Claudex.Tool.CallError{}}` instead of
  taking the caller down with it. Its `type` separates a refusal from a bug,
  and `message` is a sentence you can show or send back to Claude whatever the
  type is:

      {:error, %CallError{type: :tool_refused, message: "path is outside the workspace"}}
      {:error, %CallError{type: :tool_raised, message: "KeyError: key :missing not found in:\n\n    %{}\n"}}

  For `:tool_raised` the exception type is part of the message, so a bug reads
  differently to Claude than a considered refusal.
  """

  @spec call(module(), String.t(), map()) :: {:ok, term()} | {:error, CallError.t()}
  def call(module, name, input) when is_atom(module) and is_map(input) do
    module.__call_tool__(name, input)
  end

  @doc """
  Builds a `tool_result` content block to send back after running a tool.

  `content` must be a string or a list of content blocks, per the Messages
  API — if your tool returns something else, encode it first
  (`JSON.encode!/1` for structured data).

      iex> Claudex.Tool.result("toolu_1", "18")
      %{type: "tool_result", tool_use_id: "toolu_1", content: "18", is_error: false}

      iex> Claudex.Tool.result("toolu_1", "no such city", is_error: true)
      %{type: "tool_result", tool_use_id: "toolu_1", content: "no such city", is_error: true}
  """

  @spec result(String.t(), String.t() | [map()]) :: map()
  @spec result(String.t(), String.t() | [map()], keyword()) :: map()
  def result(tool_use_id, content, opts \\ []) do
    %{
      type: "tool_result",
      tool_use_id: tool_use_id,
      content: content,
      is_error: Keyword.get(opts, :is_error, false)
    }
  end

  @doc """
  Normalizes a `tools:` value into the plain list of tool maps the
  Messages API expects. Accepts a module that `use`s `Claudex.Tool`, a
  list mixing such modules with already-built tool maps, or `nil`.

  `Claudex.Messages.create/2` calls this on `:tools` for you, so you can
  just write `tools: MyApp.Tools` — this is public mainly for building a
  tools list ahead of time, or for something other than
  `Messages.create/2` (Batches, a hand-rolled request).

  The maps use atom keys, while the property names inside `input_schema` are
  strings, since those come from the function's parameters:

      [
        %{
          name: "add",
          description: "Adds two numbers and returns the sum. ...",
          input_schema: %{
            type: "object",
            properties: %{"a" => %{type: "number"}, "b" => %{type: "number"}},
            required: ["a", "b"],
            additionalProperties: false
          }
        }
      ]
  """

  @spec list(nil | module() | [module() | map()]) :: [map()]
  def list(nil), do: []

  def list(module) when is_atom(module), do: list([module])

  def list(modules_or_tools) when is_list(modules_or_tools),
    do: Enum.flat_map(modules_or_tools, &expand_one/1)

  @doc """
  Indexes tool modules by the tool names they implement, so a `tool_use` block
  can be routed to the module that can run it.

  Takes the same shapes as `list/1`. Plain tool maps have no implementation
  behind them, so they don't appear — a `tool_use` naming one is an unknown
  tool as far as dispatch is concerned.
  """

  @spec registry(module() | [module() | map()] | nil) :: %{String.t() => module()}
  def registry(nil), do: %{}

  def registry(module) when is_atom(module), do: registry([module])

  def registry(modules_or_tools) when is_list(modules_or_tools) do
    for module <- modules_or_tools,
        is_atom(module),
        Code.ensure_loaded?(module) and function_exported?(module, :__tools__, 0),
        tool <- module.__tools__(),
        into: %{},
        do: {tool.name, module}
  end

  defp private_tool_message(name, args, kind) do
    "`@tool` can only be attached to a public function, but #{name}/#{length(args)} " <>
      "is a #{kind} — Claudex would register a tool it can't call"
  end

  defp register(env, name, args, tool_opts) do
    module = env.module
    opts = normalize_opts(tool_opts)
    {properties, params} = schema_for(opts, name, args, module, env)
    properties = describe_args(properties, opts, name)

    input_schema = %{
      type: "object",
      properties: properties,
      required: required_params(params, properties),
      additionalProperties: false
    }

    tool = %{
      name: Atom.to_string(name),
      description: description(env, name, args),
      input_schema: input_schema
    }

    tool = if Map.get(opts, :strict, false), do: Map.put(tool, :strict, true), else: tool

    Module.put_attribute(module, :registered_tools, tool)

    Module.put_attribute(module, :tool_dispatch_entries, %{
      name: tool.name,
      function: name,
      params: params
    })

    Module.delete_attribute(module, :tool)

    :ok
  end

  # args_schema: takes full priority over @spec — when it's set, the spec
  # is never even inspected, so a type Claudex can't map can't raise for a
  # tool that doesn't need inference in the first place.
  defp schema_for(%{args_schema: args_schema}, _name, args, _module, _env) do
    {args_schema, Schema.params(args)}
  end

  defp schema_for(_opts, name, args, module, env) do
    built = Schema.build(name, args, Module.get_attribute(module, :spec), env)
    {built.properties, built.params}
  end

  defp normalize_opts(true), do: %{}

  defp normalize_opts(opts) when is_map(opts) do
    opts |> check_known_opts!() |> check_strict!() |> check_args!()
  end

  defp normalize_opts(other) do
    raise SchemaError,
      message: "`@tool` takes true or a map of options, got: #{inspect(other)}"
  end

  defp check_known_opts!(opts) do
    case Enum.find(Map.keys(opts), &(&1 not in @tool_opts)) do
      nil ->
        opts

      unknown ->
        raise SchemaError,
          message:
            "unknown `@tool` option #{inspect(unknown)} — " <>
              "`@tool` takes #{Enum.map_join(@tool_opts, " and ", &inspect/1)}"
    end
  end

  defp check_strict!(%{strict: strict} = opts) when is_boolean(strict), do: opts

  defp check_strict!(%{strict: strict}) do
    raise SchemaError,
      message: "`@tool` option :strict must be true or false, got: #{inspect(strict)}"
  end

  defp check_strict!(opts), do: opts

  defp check_args!(%{args: args} = opts) when is_list(args) do
    if Keyword.keyword?(args) and Enum.all?(args, fn {_name, text} -> is_binary(text) end) do
      opts
    else
      raise SchemaError,
        message: "`@tool` option :args must be a keyword list of argument to description"
    end
  end

  defp check_args!(%{args: args}) do
    raise SchemaError,
      message: "`@tool` option :args must be a keyword list, got: #{inspect(args)}"
  end

  defp check_args!(opts), do: opts

  defp describe_args(properties, opts, name) do
    Enum.reduce(Map.get(opts, :args, []), properties, fn {argument, description}, properties ->
      put_description(properties, Atom.to_string(argument), description, name)
    end)
  end

  defp put_description(properties, argument, description, _name)
       when is_map_key(properties, argument) do
    Map.update!(properties, argument, &Map.put(&1, :description, description))
  end

  # A renamed parameter would otherwise drop its description silently, which is
  # the failure this option exists to prevent.
  defp put_description(properties, argument, _description, name) do
    known = properties |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

    raise SchemaError,
      message:
        "`@tool args:` describes #{inspect(argument)}, but #{name} has no such " <>
          "argument — it takes #{known}"
  end

  defp required_params(params, properties) do
    params
    |> Enum.reject(fn {_name, has_default} -> has_default end)
    |> Enum.map(fn {name, _has_default} -> name end)
    |> Enum.filter(&Map.has_key?(properties, &1))
  end

  defp description(env, name, args) do
    case Module.get_attribute(env.module, :doc) do
      {_line, doc} when is_binary(doc) ->
        doc

      _no_doc ->
        IO.warn(
          "#{inspect(env.module)}.#{name}/#{length(args)} is tagged `@tool` but has no " <>
            "`@doc` — Claude picks a tool by its description, so it only sees the name",
          env
        )

        "No description provided."
    end
  end

  defp expand_one(%{} = tool), do: [tool]

  defp expand_one(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__tools__, 0) do
      module.__tools__()
    else
      raise ArgumentError,
            "#{inspect(module)} doesn't `use Claudex.Tool` — " <>
              "pass a module that does, or a list of tool maps"
    end
  end
end
