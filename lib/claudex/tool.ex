defmodule Claudex.Tool do
  @moduledoc ~S"""
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

  `mix claudex.gen.tool MyApp.Tools read_file path` writes that module, with
  every attribute in place and a description slot per argument. See
  `Mix.Tasks.Claudex.Gen.Tool`.

  Your `@doc` and `@spec` are prompt text, not developer notes. They are the
  whole of what Claude knows about the tool: the `@doc` decides whether it
  reaches for the tool at all, and the argument descriptions decide what it
  passes. Write them for the model, and expect a terse one-liner to produce a
  tool that gets called at the wrong moment or with the wrong values.

  A tool refuses a call by raising `Claudex.Tool.Error` with the reason.
  `Claudex.ToolRunner` sends the reason back as an error result, so Claude can
  try something else:

      @doc "Divides one number by another."
      @tool true
      @spec divide(number(), number()) :: float()
      def divide(a, b) do
        if b == 0, do: raise(Claudex.Tool.Error, "cannot divide by zero")

        a / b
      end

  A tool's return value reaches Claude as text: a string as it is, anything
  else as JSON. To hand Claude something to look at or cite instead, return
  content blocks. One block, or a list made only of them, is sent as content:

      @doc "Takes a screenshot of the dashboard."
      @tool true
      @spec screenshot() :: Claudex.ContentBlock.Image.t()
      def screenshot do
        MyApp.Dashboard.png()
        |> Base.encode64()
        |> Claudex.ContentBlock.Image.base64("image/png")
      end

      @doc "Searches the handbook and returns the passages found."
      @tool true
      @spec search_handbook(String.t()) :: [Claudex.ContentBlock.SearchResult.t()]
      def search_handbook(query) do
        for page <- MyApp.Handbook.search(query) do
          Claudex.ContentBlock.SearchResult.new(page.url, page.title, page.text, citations: true)
        end
      end

  Tag the value with `{:content, ...}` for blocks written as maps, or for maps
  and structs together. It takes a list, one block, or text:

      @doc "Shows a metric's chart, with what it covers."
      @tool true
      @spec chart(String.t()) :: {:content, [map() | Claudex.ContentBlock.Image.t()]}
      def chart(metric) do
        {:content,
         [
           %{type: "text", text: "Weekly #{metric}, last 12 weeks."},
           MyApp.Charts.png(metric)
           |> Base.encode64()
           |> Claudex.ContentBlock.Image.base64("image/png")
         ]}
      end

  `Claudex.ToolRunner` lists which return values are content and which are
  data.

  Pass a map instead of `true` for options:

    * `:args` - a description per argument, merged into the inferred schema
    * `:strict` - sets `strict: true` on the tool definition. Strict mode
      takes the same schema subset as `Claudex.OutputFormat`, so an inferred
      schema is fitted to it the same way: the `minimum` a
      `non_neg_integer()` implies moves into the argument's description.
      An `:args_schema` is sent as written
    * `:args_schema` - use this JSON schema for the properties instead of
      inferring one from `@spec`. Takes full priority: when it's set, the
      `@spec` is never even inspected, so it's also the way out of a type
      Claudex can't map (see below), or when you need something a
      typespec can't express (an `enum`, say). It needs a property for
      every parameter without a default, named as the parameter is
    * `:allowed_callers`, `:cache_control`, `:defer_loading`,
      `:eager_input_streaming` and `:input_examples` - copied onto the tool
      definition as given. The
      [tool reference](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference#tool-definition-properties)
      says what each one does

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

  The function receives each argument as Claude sent it, decoded from JSON,
  whatever its `@spec` type. An atom other than `true`, `false` and `nil`
  arrives as a string, so `@spec set_priority(:low | :high)` publishes
  `enum: ["low", "high"]` and is called with `"low"`. A date or time arrives as
  the string Claude sent, and a struct or keyword list as a map with string
  keys.

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

  A tool is named for its function, so `@tool` goes on one arity of a
  function at most. Tagging `add/2` and `add/3` both fails to compile, since
  they would be two tools named `"add"`. A tool name holds only ASCII
  letters, digits, `_` and `-`, up to 128 characters, so a function such as
  `valid?` or `run!` can't be a tool either.

  Naming the arguments in a `@spec`, `add(a :: number(), b :: number())`, is
  read the same as leaving them bare. The property names come from the
  function's own parameters either way. A pattern takes the name of the
  variable bound to the whole of it, as in `%{} = opts`, and one with no such
  variable, as in `def get_temperature("Tokyo")`, is published as `"arg"`,
  with a compile warning unless `:args_schema` is set. Two parameters that
  would share a name fail to compile.

  ## Structs as arguments

  A struct type in a `@spec`, such as `Ticket.t()`, expands into a nested
  object schema built from the struct's `@type t`. A struct of your own app
  declares `use Claudex.Schema` for this, and so does every struct of your
  app nested inside it:

      defmodule MyApp.Ticket do
        use Claudex.Schema

        defstruct [:title, :priority]
        @type t :: %__MODULE__{title: String.t(), priority: :low | :high}
      end

      defmodule MyApp.Tools do
        use Claudex.Tool

        @doc "Files a ticket."
        @tool true
        @spec file_ticket(MyApp.Ticket.t()) :: String.t()
        def file_ticket(ticket), do: ...
      end

  Without it, a struct compiled in the same build as the tool raises
  `Claudex.Tool.SchemaError`, naming the struct. `Claudex.Schema` says when
  a struct needs it and when it doesn't.

  An Ecto schema doesn't need `use Claudex.Schema` except to name the fields
  Claude must fill, which `Claudex.Schema` shows. It expands with its
  `embeds_one` and `embeds_many` fields included. `belongs_to`, `has_many`
  and `has_one` are skipped: they aren't part of the data, and expanding
  them risks recursing through a relationship graph.

  This only shapes the schema Claude sees. The argument your function
  receives is still the decoded JSON map, with string keys, never cast into
  the struct.

  A `@spec` type Claudex can't map raises `Claudex.Tool.SchemaError` at
  compile time. Fix the spec, or pass `:args_schema` to skip inference for
  that tool. `Claudex.OutputFormat` lists what each type becomes.
  """

  alias Claudex.ContentBlock
  alias Claudex.ContentBlock.ToolUse
  alias Claudex.Tool.{CallError, Dispatch, Schema, SchemaError}
  alias Claudex.Tool.Schema.Strict
  alias Claudex.Tracing
  alias Claudex.Tracing.Attributes

  @definition_fields [
    :allowed_callers,
    :cache_control,
    :defer_loading,
    :eager_input_streaming,
    :input_examples
  ]
  @tool_opts [:args, :args_schema, :strict | @definition_fields]
  @strict_unexpressible "A strict tool needs a concrete type for every argument, and `any()`, " <>
                          "`term()` and a struct that refers to itself have none. Give it one, " <>
                          "or pass args_schema: in the @tool options to describe it explicitly"

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
  the map doesn't matter, and a trailing optional parameter can be left out. Each
  one is passed as decoded JSON, whatever its `@spec` type.

  A tool that fails returns a `Claudex.Tool.CallError` instead of taking the
  caller down with it. Its `type` separates a refusal from a bug,
  and `message` is a sentence you can show or send back to Claude whatever the
  type is:

      {:error, %CallError{type: :tool_refused, message: "path is outside the workspace"}}
      {:error, %CallError{type: :tool_raised, message: "KeyError: key :missing not found in:\n\n    %{}\n"}}

  For `:tool_raised` the exception type is part of the message, so a bug reads
  differently to Claude than a considered refusal.

  `opts` takes `:session`, which names the conversation this call belongs to
  on its span. See `Claudex.Tracing`.
  """

  @spec call(module(), String.t(), map()) :: {:ok, term()} | {:error, CallError.t()}
  @spec call(module(), String.t(), map(), [Tracing.session_option()]) ::
          {:ok, term()} | {:error, CallError.t()}
  def call(module, name, input, opts \\ []) when is_atom(module) and is_map(input) do
    Tracing.span(fn -> Attributes.tool(name, input, opts) end, fn span ->
      :telemetry.span([:claudex, :tool], %{tool: name}, fn ->
        result = module.__call_tool__(name, input)

        record_call(result, span)

        {result, %{tool: name, outcome: outcome(result)}}
      end)
    end)
  end

  defp record_call(_result, :untraced), do: :ok

  defp record_call(result, span) do
    Tracing.set_attributes(span, Attributes.tool_outcome(outcome(result), result))

    case Attributes.tool_error(result) do
      nil -> :ok
      message -> Tracing.set_error(span, message)
    end
  end

  @doc """
  Builds a `tool_result` content block to send back after running a tool.
  Takes the `Claudex.ContentBlock.ToolUse` it answers, or that call's id.

  `content` must be a string or a list of content blocks, per the Messages
  API, and a `Claudex.ContentBlock` struct in the list is turned into the map
  the API takes. A `Claudex.ContentBlock.Text` goes without its citations,
  which the API takes only on top-level text. If your tool returns something
  else, encode it first (`Jason.encode!/1` for structured data).

  `:is_error` in `opts` marks the result as a failure Claude should react to
  rather than an answer, and defaults to `false`.

      iex> Claudex.Tool.result("toolu_1", "18")
      %{type: "tool_result", tool_use_id: "toolu_1", content: "18", is_error: false}

      iex> Claudex.Tool.result("toolu_1", "no such city", is_error: true)
      %{type: "tool_result", tool_use_id: "toolu_1", content: "no such city", is_error: true}

  An answer to a toolset's tool has to name the toolset too, which the call
  carries:

      iex> call = %Claudex.ContentBlock.ToolUse{id: "toolu_1", toolset_name: "computer"}
      iex> Claudex.Tool.result(call, "The screen is blank.")
      %{
        type: "tool_result",
        tool_use_id: "toolu_1",
        content: "The screen is blank.",
        is_error: false,
        toolset_name: "computer"
      }
  """

  @spec result(ToolUse.t() | String.t(), String.t() | [map()]) :: map()
  @spec result(ToolUse.t() | String.t(), String.t() | [map()], keyword()) :: map()
  def result(tool_use, content, opts \\ [])

  def result(%ToolUse{toolset_name: nil} = tool_use, content, opts) do
    result(tool_use.id, content, opts)
  end

  def result(%ToolUse{} = tool_use, content, opts) do
    tool_use.id |> result(content, opts) |> Map.put(:toolset_name, tool_use.toolset_name)
  end

  def result(tool_use_id, content, opts) do
    %{
      type: "tool_result",
      tool_use_id: tool_use_id,
      content: content_param(content),
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

  Tool names must be unique across the whole list, server tools included: the
  API refuses a request that lists two tools with the same name.

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

      registry = Claudex.Tool.registry([MyApp.Weather, MyApp.Math])
      #=> %{"add" => MyApp.Math, "get_weather" => MyApp.Weather}

      module = registry[tool_use.name]
      Claudex.Tool.call(module, tool_use.name, tool_use.input)

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

  defp outcome({:ok, _value}), do: :ok
  defp outcome({:error, %CallError{type: :tool_refused}}), do: :refused
  defp outcome({:error, %CallError{type: :unknown_tool}}), do: :unknown_tool
  defp outcome({:error, %CallError{}}), do: :failed

  defp private_tool_message(name, args, kind) do
    "`@tool` can only be attached to a public function, but #{name}/#{length(args)} " <>
      "is a #{kind} — Claudex would register a tool it can't call"
  end

  defp check_tool_name!(module, name, arity) do
    unless Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, Atom.to_string(name)) do
      raise SchemaError,
        message:
          "`@tool` is on #{name}/#{arity} in #{inspect(module)}, but a tool name may hold only " <>
            "ASCII letters, digits, _ and -, up to 128 characters. Rename the function"
    end
  end

  defp reject_taken_name!(module, name, arity) do
    module
    |> Module.get_attribute(:tool_dispatch_entries)
    |> Enum.find(&(&1.function == name))
    |> reject_taken(module, name, arity)
  end

  defp reject_taken(nil, _module, _name, _arity), do: :ok

  defp reject_taken(%{params: params}, module, name, arity) when length(params) == arity do
    raise SchemaError,
      message:
        "`@tool` is on two clauses of #{name}/#{arity} in #{inspect(module)}. " <>
          "A function is one tool, so put `@tool` once, above the first clause"
  end

  defp reject_taken(%{params: params}, module, name, arity) do
    raise SchemaError,
      message:
        "`@tool` is on #{name}/#{length(params)} and #{name}/#{arity} in " <>
          "#{inspect(module)}, which would be both the tool #{inspect(Atom.to_string(name))}. " <>
          "Tool names must be unique, so keep `@tool` on one of them"
  end

  defp register(env, name, args, tool_opts) do
    module = env.module
    check_tool_name!(module, name, length(args))
    reject_taken_name!(module, name, length(args))
    opts = normalize_opts(tool_opts)
    {properties, params} = schema_for(opts, name, args, module, env)
    reject_shared_names!(module, name, args, params)
    reject_uncovered_params!(module, name, args, opts, params)
    warn_unnamed(env, name, args, opts)
    properties = describe_args(properties, opts, name)

    input_schema =
      fit_strict(
        %{
          type: "object",
          properties: properties,
          required: required_params(params, properties),
          additionalProperties: false
        },
        opts
      )

    tool = %{
      name: Atom.to_string(name),
      description: description(env, name, args),
      input_schema: input_schema
    }

    tool = if Map.get(opts, :strict, false), do: Map.put(tool, :strict, true), else: tool
    tool = Map.merge(tool, Map.take(opts, @definition_fields))

    Module.put_attribute(module, :registered_tools, tool)

    Module.put_attribute(module, :tool_dispatch_entries, %{
      name: tool.name,
      function: name,
      params: params
    })

    Module.delete_attribute(module, :tool)

    :ok
  end

  defp reject_shared_names!(module, name, args, params) do
    names = Enum.map(params, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] -> :ok
      [shared | _] -> raise_shared_name!(module, name, args, names, shared)
    end
  end

  defp raise_shared_name!(module, name, args, names, shared) do
    [first, second | _] = for {arg, ^shared} <- Enum.zip(args, names), do: Macro.to_string(arg)

    raise SchemaError,
      message:
        "`@tool` is on #{name}/#{length(args)} in #{inspect(module)}, but `#{first}` and " <>
          "`#{second}` would both be the property #{inspect(shared)}. " <>
          "Give each parameter its own name"
  end

  defp reject_uncovered_params!(module, name, args, %{args_schema: schema}, params) do
    keys = for {key, _property} <- schema, do: to_string(key)

    case for({param, false} <- params, param not in keys, do: param) do
      [] ->
        :ok

      [missing | _] ->
        raise SchemaError,
          message:
            "`@tool` is on #{name}/#{length(args)} in #{inspect(module)}, but its " <>
              ":args_schema has no property #{inspect(missing)}, the name the parameter " <>
              "is read by. Add it, or rename the parameter to match"
    end
  end

  defp reject_uncovered_params!(_module, _name, _args, _opts, _params), do: :ok

  defp warn_unnamed(_env, _name, _args, %{args_schema: _schema}), do: :ok

  defp warn_unnamed(env, name, args, _opts) do
    for pattern <- Schema.unnamed(args) do
      source = Macro.to_string(pattern)

      IO.warn(
        "#{inspect(env.module)}.#{name}/#{length(args)} has a parameter, `#{source}`, " <>
          "with no name to publish, so Claude sees it as \"arg\". Name it, as in `#{source} = _name`",
        env
      )
    end
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

  defp fit_strict(input_schema, %{strict: true} = opts) when not is_map_key(opts, :args_schema),
    do: Strict.fit(input_schema, @strict_unexpressible)

  defp fit_strict(input_schema, _opts), do: input_schema

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
              "`@tool` takes #{Enum.map_join(@tool_opts, ", ", &inspect/1)}"
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

  defp content_param(blocks) when is_list(blocks), do: Enum.map(blocks, &block_param/1)
  defp content_param(text), do: text

  defp block_param(%ContentBlock.Text{} = block),
    do: ContentBlock.to_param(%{block | citations: []})

  defp block_param(%{} = block), do: ContentBlock.to_param(block)
  defp block_param(other), do: other
end
