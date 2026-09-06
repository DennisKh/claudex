defmodule Claudex.TestSupport.Recorder do
  @moduledoc """
  Captures real API payloads from the live tests into `test/fixtures/`, so the
  offline suite can replay what the API actually sent instead of JSON somebody
  typed by hand.

  Recording is off unless `CLAUDEX_RECORD_FIXTURES` is set — `mix test.record`
  sets it. When it's off, `record_json/2` and `record_stream/2` hand the client
  straight back, so live tests can call them unconditionally.

      client
      |> Recorder.record_json("message")
      |> Messages.create(params)

  Both attach a Req step to the client rather than hooking into Claudex, so
  what lands in the fixture is the payload as it came off the wire.
  """

  alias Claudex.Client

  @dir "test/fixtures"
  @env_var "CLAUDEX_RECORD_FIXTURES"

  @doc "Whether this run should overwrite fixtures."
  @spec recording?() :: boolean()
  def recording?, do: System.get_env(@env_var) in ["1", "true"]

  @doc """
  Writes the response body of every request this client makes to
  `test/fixtures/<name>.json`.
  """
  @spec record_json(Client.t(), String.t()) :: Client.t()
  def record_json(client, name) do
    update_req(client, fn req ->
      Req.Request.append_response_steps(req, claudex_record_json: &write_body(&1, name))
    end)
  end

  @doc """
  Writes the raw bytes of a streaming response to `test/fixtures/<name>.sse`,
  exactly as the server chunked them.
  """
  @spec record_stream(Client.t(), String.t()) :: Client.t()
  def record_stream(client, name) do
    update_req(client, fn req ->
      Req.Request.append_request_steps(req, claudex_record_sse: &tee_stream(&1, name))
    end)
  end

  @doc "Path of a fixture file, whether or not it exists yet."
  @spec path(String.t()) :: Path.t()
  def path(file), do: Path.join(@dir, file)

  defp update_req(%Client{} = client, fun) do
    if recording?(), do: %{client | req: fun.(client.req)}, else: client
  end

  defp write_body({request, %Req.Response{} = response}, name) do
    File.write!(path("#{name}.json"), encode(response.body))

    {request, response}
  end

  defp write_body({request, exception}, _name), do: {request, exception}

  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body, pretty: true) <> "\n"

  # A retry re-runs this step, so the file is truncated per attempt rather
  # than accumulating both responses.
  defp tee_stream(request, name) do
    if is_function(request.into, 2) do
      File.write!(path("#{name}.sse"), "")
      update_in(request.into, &tee(&1, "#{name}.sse"))
    else
      request
    end
  end

  defp tee(into, file) do
    fn {:data, data}, acc ->
      File.write!(path(file), data, [:append])
      into.({:data, data}, acc)
    end
  end
end
