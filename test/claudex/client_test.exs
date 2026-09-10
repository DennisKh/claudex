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

  defp request, do: Req.new()

  defp response(status, headers \\ []) do
    Enum.reduce(headers, %Req.Response{status: status}, fn {name, value}, response ->
      Req.Response.put_header(response, name, value)
    end)
  end

  test "retry_decision/2 retries rate limits, 5xx, and proxy timeouts" do
    for status <- [408, 429, 500, 503, 504, 529] do
      assert Client.retry_decision(request(), response(status)) == true
    end

    for status <- [200, 400, 401, 402, 404, 413, 422] do
      refute Client.retry_decision(request(), response(status))
    end
  end

  test "retry_decision/2 retries a connection that never reached the API" do
    assert Client.retry_decision(request(), %Req.TransportError{reason: :closed}) == true
    assert Client.retry_decision(request(), %Req.TransportError{reason: :timeout}) == true
  end

  test "retry_decision/2 does not retry a 409, which the API says to resolve first" do
    refute Client.retry_decision(request(), response(409))
  end

  describe "retry-after" do
    test "a 529 naming a delay is retried after that long" do
      overloaded = response(529, [{"retry-after", "30"}])

      assert Client.retry_decision(request(), overloaded) == {:delay, 30_000}
    end

    test "a 529 with no delay falls back to Req's backoff" do
      assert Client.retry_decision(request(), response(529)) == true
    end

    # Req reads the header itself for these two and handles the date form.
    test "429 and 503 are left to Req" do
      assert Client.retry_decision(request(), response(429, [{"retry-after", "30"}])) == true
      assert Client.retry_decision(request(), response(503, [{"retry-after", "30"}])) == true
    end

    test "a negative delay is ignored rather than passed to Process.sleep/1" do
      assert Client.retry_decision(request(), response(529, [{"retry-after", "-5"}])) == true
    end

    test "a zero delay is honoured as an immediate retry" do
      assert Client.retry_decision(request(), response(529, [{"retry-after", "0"}])) ==
               {:delay, 0}
    end

    test "an HTTP-date delay is ignored rather than misread" do
      dated = response(529, [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}])

      assert Client.retry_decision(request(), dated) == true
    end

    # Req raises if :retry_delay is set and the retry fun returns {:delay, _}.
    test "a caller's own retry_delay wins, because Req refuses to combine them" do
      configured = Req.new(retry_delay: 0)

      assert Client.retry_decision(configured, response(529, [{"retry-after", "30"}])) == true
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
