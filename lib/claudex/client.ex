defmodule Claudex.Client do
  @moduledoc """
  Connection settings for talking to the Claude API: your API key, the base
  URL, and how to handle timeouts and retries.

  Build one with `new/1` and pass it to functions like
  `Claudex.Messages.create/2`. Clients are plain structs, so you can hold
  several at once (different keys, different workspaces) without any shared
  process state.
  """

  @default_base_url "https://api.anthropic.com"

  @missing_api_key "no API key given: pass `api_key:` to Claudex.Client.new/1, set it in " <>
                     "`config :claudex, api_key: ...`, or set ANTHROPIC_API_KEY"
  @default_max_retries 2
  @default_receive_timeout :timer.minutes(10)
  @default_connect_timeout :timer.seconds(5)
  @anthropic_version "2023-06-01"

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
      They become one `anthropic-beta` header, which is all a beta parameter
      needs: it then passes through `Claudex.Messages.create/2` like any other.
    * `:req_options` - extra options merged into the underlying `Req.new/1`
      call, for anything not covered above (a custom `:adapter` for tests,
      a `:finch` pool, ...).

  If you need an error tuple to be returned, use `build/1` instead.
  """
  @spec new() :: t()
  @spec new(keyword()) :: t()
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
  @spec build(keyword()) :: {:ok, t()} | {:error, :missing_api_key}
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
        headers: default_headers(api_key) ++ beta_headers(beta)
      ]
      |> merge_req_options(req_options)
      |> Req.new()

    %__MODULE__{api_key: api_key, req: req, base_url: base_url, max_retries: max_retries}
  end

  @doc """
  Decides whether a failed request should be retried, and how long to wait
  first. This is the `:retry` function every Claudex client is built with.

  Returns `false` to give up, `true` to retry on Req's exponential backoff, or
  `{:delay, milliseconds}` to wait exactly that long — the last of these when
  the response named a `retry-after`, for the statuses Req doesn't already
  read that header on itself.

  Connection errors, rate limits and 5xx are retried. A 409 is not: the API
  says to resolve the conflict first, so repeating the request can only fail
  again or duplicate work. A 408 is, because it comes from a proxy that gave
  up before the request reached the model — nothing was generated and nothing
  was billed, so the retry costs only the round trip.
  """
  @spec retry_decision(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          boolean() | {:delay, non_neg_integer()}
  def retry_decision(request, %Req.Response{status: status} = response) do
    if status in [408, 429] or status >= 500 do
      server_delay(request, response) || true
    else
      false
    end
  end

  def retry_decision(_request, %{__exception__: true}), do: true

  defp default_headers(api_key) do
    [
      {"x-api-key", api_key},
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

  # Req reads `retry-after` itself, but only for 429 and 503. Anthropic signals
  # overload with 529 and may name a delay there, so honour it for the statuses
  # Req leaves alone. Skipped when the caller set their own `:retry_delay`,
  # which Req refuses to combine with a `{:delay, _}` return.
  defp server_delay(_request, %Req.Response{status: status}) when status in [429, 503], do: nil

  defp server_delay(request, response) do
    with nil <- Req.Request.get_option(request, :retry_delay),
         [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(value) do
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
