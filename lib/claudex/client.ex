defmodule Claudex.Client do
  @moduledoc """
  Connection settings for talking to the Claude API: your API key, the base
  URL, and how to handle timeouts and retries.

  Build one with `new/1` and pass it to functions like
  `Claudex.Messages.create/2`. Clients are plain structs, so you can hold
  several at once (different keys, different workspaces) without any shared
  process state.

  A client hides its API key when inspected:

      iex> inspect(Claudex.new(api_key: "sk-ant-secret"))
      "#Claudex.Client<base_url: \"https://api.anthropic.com\", max_retries: 2, ...>"

  That covers logs, `IO.inspect`, and crash reports. One gap to know about:
  `client.req` is a `Req.Request` that carries the key in its `x-api-key`
  header, and inspecting *that* directly still prints it.
  """

  @default_base_url "https://api.anthropic.com"
  @default_max_retries 2
  @default_receive_timeout :timer.minutes(10)
  @default_connect_timeout :timer.seconds(5)
  @anthropic_version "2023-06-01"

  # Inspecting a client must not print the key. `:req` is hidden for the same
  # reason — it carries the key in its `x-api-key` header. Both fields still
  # work normally; only `inspect/1` is affected.
  @derive {Inspect, only: [:base_url, :max_retries]}
  @enforce_keys [:api_key, :req]
  defstruct [:api_key, :req, base_url: @default_base_url, max_retries: @default_max_retries]

  @type t :: %__MODULE__{
          api_key: String.t(),
          req: Req.Request.t(),
          base_url: String.t(),
          max_retries: non_neg_integer()
        }

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
    * `:max_retries` - retries for transient errors (429, 5xx, timeouts),
      defaults to `#{@default_max_retries}`.
    * `:receive_timeout` - how long to wait for a response once connected,
      in milliseconds, defaults to 10 minutes.
    * `:connect_timeout` - how long to wait for the TCP/TLS handshake, in
      milliseconds, defaults to 5 seconds — a slow or unreachable host
      fails fast instead of hanging for the full `:receive_timeout`.
    * `:beta` - beta features to opt into, as a string or a list of them.
      They become one `anthropic-beta` header.
    * `:req_options` - extra options merged into the underlying `Req.new/1`
      call, for anything not covered above (a custom `:adapter` for tests,
      a `:finch` pool, ...). A `:headers` or `:connect_options` entry here
      is merged with — not replacing — the defaults above, so you can add
      an extra header or transport option without losing the rest.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api_key = fetch_api_key!(opts)
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
        retry: &retry?/2,
        headers: default_headers(api_key) ++ beta_headers(beta)
      ]
      |> merge_req_options(req_options)
      |> Req.new()

    %__MODULE__{api_key: api_key, req: req, base_url: base_url, max_retries: max_retries}
  end

  defp default_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"user-agent", user_agent()}
    ]
  end

  # Keyword.merge/2 replaces a key wholesale rather than combining it, so a
  # blind merge of req_options would silently drop the default auth headers
  # (or connect options) the moment a caller sets their own. Merge those two
  # keys explicitly; everything else in req_options overrides normally.
  defp merge_req_options(defaults, req_options) do
    {extra_headers, req_options} = Keyword.pop(req_options, :headers, [])
    {extra_connect_options, req_options} = Keyword.pop(req_options, :connect_options, [])

    defaults
    |> Keyword.update!(:headers, &merge_headers(&1, extra_headers))
    |> Keyword.update!(:connect_options, &Keyword.merge(&1, extra_connect_options))
    |> Keyword.merge(req_options)
  end

  # Req accumulates same-named headers rather than replacing them, so a
  # caller overriding one would end up sending it twice. Drop the default
  # whenever the caller supplies that header themselves.
  defp merge_headers(defaults, extra) do
    extra_names = Enum.map(extra, fn {name, _value} -> String.downcase(name) end)

    Enum.reject(defaults, fn {name, _value} -> String.downcase(name) in extra_names end) ++ extra
  end

  @doc false
  @spec retry?(Req.Request.t(), Req.Response.t() | Exception.t()) :: boolean()
  # The API documents retrying connection errors, rate limits, and 5xx. Two
  # calls beyond that: 409 is not retried, because the docs say to resolve the
  # conflict first, so repeating the request can only fail again or duplicate
  # work. 408 is retried — it isn't a status this API returns, it comes from a
  # proxy that gave up before the request reached the model, so nothing was
  # generated and nothing was billed; the retry costs only the round trip.
  def retry?(request, %Req.Response{status: status} = response) do
    if status in [408, 429] or status >= 500 do
      server_delay(request, response) || true
    else
      false
    end
  end

  def retry?(_request, %{__exception__: true}), do: true

  # Req reads `retry-after` itself, but only for 429 and 503. Anthropic signals
  # overload with 529 and may name a delay there, so honour it for the statuses
  # Req leaves alone. Skipped when the caller set their own `:retry_delay`,
  # which Req refuses to combine with a `{:delay, _}` return.
  defp server_delay(_request, %Req.Response{status: status}) when status in [429, 503], do: nil

  defp server_delay(request, response) do
    with nil <- Req.Request.get_option(request, :retry_delay),
         [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(value) do
      {:delay, seconds * 1000}
    else
      _no_usable_delay -> nil
    end
  end

  defp option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:claudex, key, default)
    end
  end

  defp fetch_api_key!(opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, api_key} -> api_key
      :error -> configured_api_key!()
    end
  end

  defp configured_api_key! do
    Application.get_env(:claudex, :api_key) || System.get_env("ANTHROPIC_API_KEY") ||
      raise ArgumentError,
            "no API key given: pass `api_key:` to Claudex.Client.new/1, set it in " <>
              "`config :claudex, api_key: ...`, or set ANTHROPIC_API_KEY"
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
