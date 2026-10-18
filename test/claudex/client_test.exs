defmodule Claudex.ClientTest do
  use ExUnit.Case, async: false

  alias Claudex.Client

  test "new/1 uses the given api_key" do
    client = Client.new(api_key: "sk-ant-explicit")

    assert client.api_key == "sk-ant-explicit"
  end

  test "new/1 falls back to the ANTHROPIC_API_KEY environment variable" do
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-env")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

    client = Client.new()

    assert client.api_key == "sk-ant-from-env"
  end

  test "new/1 raises without an api_key or the environment variable" do
    System.delete_env("ANTHROPIC_API_KEY")

    assert_raise ArgumentError, ~r/no API key given/, fn -> Client.new() end
  end

  test "new/1 sets the required headers" do
    client = Client.new(api_key: "sk-ant-test")

    assert Req.Request.get_header(client.req, "x-api-key") == ["sk-ant-test"]
    assert Req.Request.get_header(client.req, "anthropic-version") == ["2023-06-01"]
  end

  test "new/1 keeps the default headers when req_options adds its own" do
    client =
      Client.new(api_key: "sk-ant-test", req_options: [headers: [{"x-request-id", "abc"}]])

    assert Req.Request.get_header(client.req, "x-api-key") == ["sk-ant-test"]
    assert Req.Request.get_header(client.req, "anthropic-version") == ["2023-06-01"]
    assert Req.Request.get_header(client.req, "x-request-id") == ["abc"]
  end

  test "new/1 lets req_options override a specific default header" do
    client =
      Client.new(
        api_key: "sk-ant-test",
        req_options: [headers: [{"anthropic-version", "2099-01-01"}]]
      )

    assert Req.Request.get_header(client.req, "anthropic-version") == ["2099-01-01"]
    assert Req.Request.get_header(client.req, "x-api-key") == ["sk-ant-test"]
  end

  test "new/1 sets a connect timeout, overridable and mergeable" do
    default = Client.new(api_key: "sk-ant-test")
    assert default.req.options.connect_options[:timeout] == :timer.seconds(5)

    custom = Client.new(api_key: "sk-ant-test", connect_timeout: 1_000)
    assert custom.req.options.connect_options[:timeout] == 1_000

    merged =
      Client.new(
        api_key: "sk-ant-test",
        req_options: [connect_options: [transport_opts: [inet6: true]]]
      )

    assert merged.req.options.connect_options[:timeout] == :timer.seconds(5)
    assert merged.req.options.connect_options[:transport_opts] == [inet6: true]
  end

  test "new/1 defaults base_url and max_retries" do
    client = Client.new(api_key: "sk-ant-test")

    assert client.base_url == "https://api.anthropic.com"
    assert client.max_retries == 2
  end

  defp request(retry_count \\ 0) do
    Req.Request.put_private(Req.new(), :req_retry_count, retry_count)
  end

  defp response(status, headers \\ []) do
    Enum.reduce(headers, %Req.Response{status: status}, fn {name, value}, response ->
      Req.Response.put_header(response, name, value)
    end)
  end

  defp assert_backoff(decision, low, high) do
    assert {:delay, delay} = decision
    assert delay in low..high
  end

  test "retry_decision/2 retries proxy timeouts, conflicts, rate limits and 5xx" do
    for status <- [408, 409, 429, 500, 503, 504, 529] do
      assert {:delay, _delay} = Client.retry_decision(request(), response(status))
    end

    for status <- [200, 400, 401, 402, 404, 413, 422] do
      refute Client.retry_decision(request(), response(status))
    end
  end

  test "retry_decision/2 retries a connection that never reached the API" do
    assert {:delay, _delay} =
             Client.retry_decision(request(), %Req.TransportError{reason: :closed})

    assert {:delay, _delay} =
             Client.retry_decision(request(), %Req.TransportError{reason: :timeout})
  end

  describe "x-should-retry" do
    test "false stops a retry the status would allow" do
      refute Client.retry_decision(request(), response(529, [{"x-should-retry", "false"}]))
    end

    test "true retries a status that would not be" do
      assert {:delay, _delay} =
               Client.retry_decision(request(), response(400, [{"x-should-retry", "true"}]))
    end

    test "any other value leaves the decision to the status" do
      refute Client.retry_decision(request(), response(400, [{"x-should-retry", "yes"}]))

      assert {:delay, _delay} =
               Client.retry_decision(request(), response(529, [{"x-should-retry", "yes"}]))
    end
  end

  describe "backoff" do
    test "starts at half a second and doubles, shortened by up to a quarter" do
      assert_backoff(Client.retry_decision(request(0), response(529)), 375, 500)
      assert_backoff(Client.retry_decision(request(1), response(529)), 750, 1000)
      assert_backoff(Client.retry_decision(request(2), response(529)), 1500, 2000)
    end

    test "stops growing at 8 seconds" do
      assert_backoff(Client.retry_decision(request(4), response(529)), 6000, 8000)
      assert_backoff(Client.retry_decision(request(20), response(529)), 6000, 8000)
    end

    test "varies from one retry to the next" do
      delays = for _attempt <- 1..50, do: Client.retry_decision(request(), response(529))

      assert delays |> Enum.uniq() |> length() > 1
    end

    test "applies to a connection error too" do
      assert_backoff(
        Client.retry_decision(request(1), %Req.TransportError{reason: :closed}),
        750,
        1000
      )
    end
  end

  describe "server delay" do
    test "retry-after is read as seconds, fractions included" do
      assert Client.retry_decision(request(), response(529, [{"retry-after", "30"}])) ==
               {:delay, 30_000}

      assert Client.retry_decision(request(), response(429, [{"retry-after", "1.5"}])) ==
               {:delay, 1_500}
    end

    test "retry-after-ms is read as milliseconds and wins over retry-after" do
      headers = [{"retry-after-ms", "250.4"}, {"retry-after", "30"}]

      assert Client.retry_decision(request(), response(503, headers)) == {:delay, 250}
    end

    test "is followed past the 8-second backoff cap" do
      assert Client.retry_decision(request(), response(429, [{"retry-after", "60"}])) ==
               {:delay, 60_000}
    end

    test "a zero, negative, dated or garbled value falls back to the backoff" do
      for value <- ["0", "-5", "Wed, 21 Oct 2026 07:28:00 GMT", "soon"] do
        assert_backoff(
          Client.retry_decision(request(), response(529, [{"retry-after", value}])),
          375,
          500
        )

        assert_backoff(
          Client.retry_decision(request(), response(529, [{"retry-after-ms", value}])),
          375,
          500
        )
      end
    end

    # Req raises if :retry_delay is set and the retry fun returns {:delay, _}.
    test "a caller's own retry_delay wins, because Req refuses to combine them" do
      configured = Req.new(retry_delay: 0)

      assert Client.retry_decision(configured, response(529, [{"retry-after", "30"}])) == true
      assert Client.retry_decision(configured, response(529)) == true
    end
  end

  describe "retries through Req" do
    defp stubbed_client do
      Client.new(api_key: "sk-ant-test", req_options: [plug: {Req.Test, __MODULE__}])
    end

    test "a 529 marked x-should-retry: false is sent once" do
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, :attempt)

        conn
        |> Plug.Conn.put_resp_header("x-should-retry", "false")
        |> Plug.Conn.send_resp(529, "")
      end)

      assert {:ok, %Req.Response{status: 529}} = Req.get(stubbed_client().req, url: "/v1/models")

      assert_received :attempt
      refute_received :attempt
    end

    @tag :capture_log
    test "each retry waits longer than the last" do
      Req.Test.expect(__MODULE__, 2, &Plug.Conn.send_resp(&1, 503, ""))
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{}))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %Req.Response{status: 200}} =
                   Req.get(stubbed_client().req, url: "/v1/models")
        end)

      assert [first, second] =
               ~r/will retry in (\d+)ms/
               |> Regex.scan(log, capture: :all_but_first)
               |> Enum.map(fn [delay] -> String.to_integer(delay) end)

      assert first in 375..500
      assert second in 750..1000
    end
  end

  describe "put_header/3" do
    test "sets a header alongside the ones the client already sends" do
      client =
        Client.new(api_key: "sk-ant-test")
        |> Client.put_header("anthropic-workspace-id", "wrkspc_1")

      assert Req.Request.get_header(client.req, "anthropic-workspace-id") == ["wrkspc_1"]
      assert Req.Request.get_header(client.req, "x-api-key") == ["sk-ant-test"]
    end

    test "replaces a header of the same name" do
      client =
        Client.new(api_key: "sk-ant-test")
        |> Client.put_header("anthropic-workspace-id", "wrkspc_1")
        |> Client.put_header("Anthropic-Workspace-Id", "wrkspc_2")

      assert Req.Request.get_header(client.req, "anthropic-workspace-id") == ["wrkspc_2"]
    end

    test "is sent with a request made through the client" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "input_tokens" => 1,
          "sent" => Plug.Conn.get_req_header(conn, "anthropic-workspace-id")
        })
      end)

      client =
        Client.new(api_key: "sk-ant-test", req_options: [plug: {Req.Test, __MODULE__}])
        |> Client.put_header("anthropic-workspace-id", "wrkspc_1")

      assert {:ok, %{"sent" => ["wrkspc_1"]}} = Claudex.API.get(client, "/v1/models")
    end
  end

  describe "put_beta/2" do
    test "sets the beta header on a client without one" do
      client = Client.new(api_key: "sk-ant-test") |> Client.put_beta("files-api-2025-04-14")

      assert Req.Request.get_header(client.req, "anthropic-beta") == ["files-api-2025-04-14"]
    end

    test "adds to the client's own betas in the one header" do
      client =
        Client.new(api_key: "sk-ant-test", beta: "files-api-2025-04-14")
        |> Client.put_beta(["fast-mode-2026-02-01", "user-profiles-2026-08-18"])

      assert Req.Request.get_header(client.req, "anthropic-beta") ==
               ["files-api-2025-04-14,fast-mode-2026-02-01,user-profiles-2026-08-18"]
    end

    test "adds no header for an empty list" do
      client = Client.new(api_key: "sk-ant-test") |> Client.put_beta([])

      assert Req.Request.get_header(client.req, "anthropic-beta") == []
    end
  end

  describe "inspect/1" do
    test "never prints the API key" do
      client = Client.new(api_key: "sk-ant-hunter2")

      printed = inspect(client)

      refute printed =~ "hunter2"
      refute printed =~ "sk-ant"
      assert printed =~ "base_url"
      assert printed =~ "max_retries"
    end

    test "stays hidden inside other data, which is where leaks happen" do
      client = Client.new(api_key: "sk-ant-hunter2")

      refute inspect(%{client: client}) =~ "hunter2"
      refute inspect([client]) =~ "hunter2"
      refute inspect({:ok, client}) =~ "hunter2"
      refute "#{inspect(client)}" =~ "hunter2"
    end

    test "the key is still there to use" do
      client = Client.new(api_key: "sk-ant-hunter2")

      assert client.api_key == "sk-ant-hunter2"
    end
  end
end
