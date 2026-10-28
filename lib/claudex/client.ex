defmodule Claudex.Client do
  @moduledoc """
  Connection settings for talking to the Claude API: your API key, the base
  URL, and how to handle timeouts and retries.

  Build one with `new/1` and pass it to functions like
  `Claudex.Messages.create/2`. Clients are plain structs, so you can hold
  several at once (different keys, different workspaces) without any shared
  process state. `put_header/3` and `put_beta/2` return a copy with a header
  or a beta added, for the requests that need it.

  Requests go out with API version `2026-10-21`, which answers `temperature`,
  `top_p` or `top_k`, a `document` block directly in an `assistant` message,
  and a `text` block with `citations` in a `user` message with a 400. The
  [migration guide](https://platform.claude.com/docs/en/api/migration-2026-10-21)
  has the details. A copy made with
  `put_header(client, "anthropic-version", "2023-06-01")` sends the previous
  version, for a request that still needs one of them.
  """

  @default_base_url "https://api.anthropic.com"

  @missing_api_key "no API key given: pass `api_key:` to Claudex.Client.new/1, set it in " <>
                     "`config :claudex, api_key: ...`, or set ANTHROPIC_API_KEY"
  @default_max_retries 2
  @default_receive_timeout :timer.minutes(10)
  @initial_retry_delay 500
  @max_retry_delay :timer.seconds(8)
  @default_connect_timeout :timer.seconds(5)
  @anthropic_version "2026-10-21"

  @derive {Inspect, only: [:base_url, :max_retries]}
  @enforce_keys [:api_key, :req]
  defstruct [:api_key, :req, base_url: @default_base_url, max_retries: @default_max_retries]

  @type t :: %__MODULE__{
          api_key: String.t(),
          req: Req.Request.t(),
          base_url: String.t(),
          max_retries: non_neg_integer()
        }

  @typedoc """
  An option for `new/1` and `build/1`, each described under "Options" in
  `new/1`. Every one can also be set in application config.
  """
  @type option ::
          {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:max_retries, non_neg_integer()}
          | {:receive_timeout, timeout()}
          | {:connect_timeout, timeout()}
          | {:beta, String.t() | [String.t()]}
          | {:req_options, keyword()}

  @doc """
  Builds a client.

  Every option can also be set in application config, so an app names its
  connection settings once:

      config :claudex,
        api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
        max_retries: 3

      client = Claudex.new()

  An option passed here wins over application config.

  ## Options

    * `:api_key` - your Anthropic API key. Falls back to application config,
      then to the `ANTHROPIC_API_KEY` environment variable. Raises if none of
      the three is set.
    * `:base_url` - defaults to `#{inspect(@default_base_url)}`.
    * `:max_retries` - how many times a failed request is retried, defaults
      to `#{@default_max_retries}`. `retry_decision/2` says which failures
      are retried and how long each wait is.
    * `:receive_timeout` - how long to wait for a response once connected,
      in milliseconds, defaults to 10 minutes. A non-streaming reply arrives
      only once it is complete, and it can take up to an hour per 128,000
      tokens of `max_tokens`. A request that times out is retried, up to
      `:max_retries` times. With the default, `Claudex.Messages.create/2`
      refuses a `max_tokens` that can outlast it; a timeout of your own is
      not checked.
    * `:connect_timeout` - how long to wait for the TCP/TLS handshake, in
      milliseconds, defaults to 5 seconds — a slow or unreachable host
      fails fast instead of hanging for the full `:receive_timeout`.
    * `:beta` - beta features to opt into, as a string or a list of them.
      They become one `anthropic-beta` header, which is all a beta parameter
      needs: it then passes through `Claudex.Messages.create/2` like any other.
    * `:req_options` - extra options merged into the underlying `Req.new/1`
      call, for anything not covered above (a custom `:adapter` for tests,
      a `:finch` pool, ...).

  If you need an error tuple to be returned, use `build/1` instead.
  """
  @spec new() :: t()
  @spec new([option()]) :: t()
  def new(opts \\ []) do
    case build(opts) do
      {:ok, client} -> client
      {:error, :missing_api_key} -> raise ArgumentError, @missing_api_key
    end
  end

  @doc """
  Builds a client, the same as `new/1`. Returns an error tuple when API key is missing.

      case Claudex.Client.build() do
        {:ok, client} -> client
        {:error, :missing_api_key} -> :needs_setup
      end

  Every other option is applied the same way. For more details, see [new/1 Options](#new/1-options)
  """
  @spec build() :: {:ok, t()} | {:error, :missing_api_key}
  @spec build([option()]) :: {:ok, t()} | {:error, :missing_api_key}
  def build(opts \\ []) do
    case api_key(opts) do
      nil -> {:error, :missing_api_key}
      api_key -> {:ok, client(api_key, opts)}
    end
  end

  defp client(api_key, opts) do
    base_url = option(opts, :base_url, @default_base_url)
    max_retries = option(opts, :max_retries, @default_max_retries)
    receive_timeout = option(opts, :receive_timeout, @default_receive_timeout)
    connect_timeout = option(opts, :connect_timeout, @default_connect_timeout)
    beta = option(opts, :beta, [])
    req_options = option(opts, :req_options, [])

    req =
      [
        base_url: base_url,
        receive_timeout: receive_timeout,
        connect_options: [timeout: connect_timeout],
        max_retries: max_retries,
        retry: &retry_decision/2,
        headers: default_headers() ++ beta_headers(beta)
      ]
      |> merge_req_options(req_options)
      |> Req.new()
      |> Req.Request.append_request_steps(claudex_api_key: api_key_step(api_key))

    %__MODULE__{api_key: api_key, req: req, base_url: base_url, max_retries: max_retries}
  end

  @doc """
  Returns a copy of the client that sends header `name` with `value` on every
  request, replacing a header of the same name. The original client is
  unchanged, and building the copy opens no connection.

  Picks the workspace for a credential that can act on more than one:

      client
      |> Claudex.Client.put_header("anthropic-workspace-id", "wrkspc_011CZkZaBF1tNoB5wlCeusgy")
      |> Claudex.Messages.create(params)

  `anthropic-user-profile-id` attributes a request to a user profile, and
  needs the user profiles beta from `put_beta/2` as well.
  """
  @spec put_header(t(), String.t(), String.t()) :: t()
  def put_header(%__MODULE__{} = client, name, value) when is_binary(name) and is_binary(value) do
    %{client | req: Req.Request.put_header(client.req, name, value)}
  end

  @doc """
  Returns a copy of the client with more beta features, as a string or a list
  of them, added to the ones it already sends. The original client is
  unchanged. `put_header/3` with `"anthropic-beta"` replaces the client's betas
  instead.

      client
      |> Claudex.Client.put_beta("fast-mode-2026-02-01")
      |> Claudex.Messages.create(params)
  """
  @spec put_beta(t(), String.t() | [String.t()]) :: t()
  def put_beta(%__MODULE__{} = client, []), do: client

  def put_beta(%__MODULE__{} = client, beta) when is_binary(beta) or is_list(beta) do
    betas = Req.Request.get_header(client.req, "anthropic-beta") ++ List.wrap(beta)

    put_header(client, "anthropic-beta", Enum.join(betas, ","))
  end

  @doc """
  Decides whether a failed request should be retried, and how long to wait
  first. This is the `:retry` function every Claudex client is built with.

  Returns `false` to give up, or `{:delay, milliseconds}` to retry after
  that long. When the client's `:req_options` set Req's own `:retry_delay`,
  returns `true` instead and Req waits that long.

  An `x-should-retry` header of `true` or `false` on the response decides.
  Without one, a 408, 409, 429 or 5xx is retried, and so is a request that
  never got a response. The wait is the response's `retry-after-ms` or
  `retry-after` when it names one, and otherwise starts at half a second,
  doubling with each retry up to 8 seconds, each wait shortened by up to a
  quarter at random.
  """
  @spec retry_decision(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          boolean() | {:delay, non_neg_integer()}
  def retry_decision(request, %Req.Response{} = response) do
    retry? =
      case Req.Response.get_header(response, "x-should-retry") do
        ["true" | _rest] -> true
        ["false" | _rest] -> false
        _unset -> retryable_status?(response.status)
      end

    retry? and retry_delay(request, response)
  end

  def retry_decision(request, %{__exception__: true}), do: retry_delay(request, nil)

  @doc false
  @spec default_receive_timeout?(t()) :: boolean()
  def default_receive_timeout?(%__MODULE__{req: req}) do
    Req.Request.get_option(req, :receive_timeout) == @default_receive_timeout
  end

  defp api_key_step(api_key) do
    &Req.Request.put_new_header(&1, "x-api-key", api_key)
  end

  defp default_headers do
    [
      {"anthropic-version", @anthropic_version},
      {"user-agent", user_agent()}
    ]
  end

  defp merge_req_options(defaults, req_options) do
    {extra_headers, req_options} = Keyword.pop(req_options, :headers, [])
    {extra_connect_options, req_options} = Keyword.pop(req_options, :connect_options, [])

    defaults
    |> Keyword.update!(:headers, &merge_headers(&1, extra_headers))
    |> Keyword.update!(:connect_options, &Keyword.merge(&1, extra_connect_options))
    |> Keyword.merge(req_options)
  end

  defp merge_headers(defaults, extra) do
    extra_names = Enum.map(extra, fn {name, _value} -> String.downcase(name) end)

    Enum.reject(defaults, fn {name, _value} -> String.downcase(name) in extra_names end) ++ extra
  end

  defp retryable_status?(status), do: status in [408, 409, 429] or status >= 500

  defp retry_delay(request, response) do
    if Req.Request.get_option(request, :retry_delay),
      do: true,
      else: {:delay, server_delay(response) || backoff(request)}
  end

  defp server_delay(nil), do: nil

  defp server_delay(response) do
    header_delay(response, "retry-after-ms", 1) || header_delay(response, "retry-after", 1000)
  end

  defp header_delay(response, name, unit_ms) do
    with [value | _rest] <- Req.Response.get_header(response, name),
         {amount, ""} when amount > 0 <- Float.parse(value) do
      round(amount * unit_ms)
    else
      _no_usable_delay -> nil
    end
  end

  defp backoff(request) do
    retries = Req.Request.get_private(request, :req_retry_count, 0)
    delay = min(@initial_retry_delay * 2 ** retries, @max_retry_delay)

    round(delay * (1 - 0.25 * :rand.uniform()))
  end

  defp option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:claudex, key, default)
    end
  end

  defp api_key(opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, api_key} -> api_key
      :error -> Application.get_env(:claudex, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    end
  end

  defp beta_headers([]), do: []

  defp beta_headers(beta) when is_binary(beta), do: beta_headers([beta])

  defp beta_headers(betas) when is_list(betas), do: [{"anthropic-beta", Enum.join(betas, ",")}]

  defp user_agent do
    version =
      case Application.spec(:claudex, :vsn) do
        nil -> "dev"
        vsn -> List.to_string(vsn)
      end

    "claudex/#{version}"
  end
end
