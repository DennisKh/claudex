defmodule Claudex.ClientConfigTest do
  @moduledoc """
  Application config is global, so these run sync and put everything back.
  """

  use ExUnit.Case, async: false

  alias Claudex.{Client, Message, Messages}

  @keys [
    :api_key,
    :base_url,
    :max_retries,
    :receive_timeout,
    :connect_timeout,
    :beta,
    :req_options
  ]

  setup do
    env = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      Enum.each(@keys, &Application.delete_env(:claudex, &1))

      case env do
        nil -> System.delete_env("ANTHROPIC_API_KEY")
        value -> System.put_env("ANTHROPIC_API_KEY", value)
      end
    end)

    System.delete_env("ANTHROPIC_API_KEY")

    :ok
  end

  defp header(client, name) do
    client.req.headers |> Map.get(name, []) |> List.first()
  end

  describe "api key" do
    test "comes from application config" do
      Application.put_env(:claudex, :api_key, "sk-ant-from-config")

      assert Client.new().api_key == "sk-ant-from-config"
    end

    test "an explicit option wins over application config" do
      Application.put_env(:claudex, :api_key, "sk-ant-from-config")

      assert Client.new(api_key: "sk-ant-explicit").api_key == "sk-ant-explicit"
    end

    test "application config wins over the environment variable" do
      Application.put_env(:claudex, :api_key, "sk-ant-from-config")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-env")

      assert Client.new().api_key == "sk-ant-from-config"
    end

    test "the environment variable is still the last resort" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-env")

      assert Client.new().api_key == "sk-ant-from-env"
    end

    test "raises when it is set nowhere, naming all three places" do
      assert_raise ArgumentError, ~r/api_key.*config :claudex.*ANTHROPIC_API_KEY/s, fn ->
        Client.new()
      end
    end
  end

  describe "connection settings" do
    setup do
      Application.put_env(:claudex, :api_key, "sk-ant-test")
    end

    test "come from application config" do
      Application.put_env(:claudex, :base_url, "https://proxy.internal")
      Application.put_env(:claudex, :max_retries, 5)
      Application.put_env(:claudex, :receive_timeout, 1_000)
      Application.put_env(:claudex, :connect_timeout, 250)

      client = Client.new()

      assert client.base_url == "https://proxy.internal"
      assert client.max_retries == 5
      assert client.req.options[:receive_timeout] == 1_000
      assert client.req.options[:connect_options][:timeout] == 250
    end

    test "an explicit option wins over application config" do
      Application.put_env(:claudex, :base_url, "https://proxy.internal")

      assert Client.new(base_url: "http://localhost:4000").base_url == "http://localhost:4000"
    end

    test "a configured max_retries of 0 is respected" do
      Application.put_env(:claudex, :max_retries, 0)

      assert Client.new().max_retries == 0
    end

    test "an explicit max_retries of 0 beats a configured 2" do
      Application.put_env(:claudex, :max_retries, 2)

      assert Client.new(max_retries: 0).max_retries == 0
    end

    test "req_options come from application config too" do
      Application.put_env(:claudex, :req_options, plug: {Req.Test, __MODULE__})

      assert Client.new().req.options[:plug] == {Req.Test, __MODULE__}
    end
  end

  describe "beta features" do
    setup do
      Application.put_env(:claudex, :api_key, "sk-ant-test")
    end

    test "no header unless asked for" do
      assert header(Client.new(), "anthropic-beta") == nil
    end

    test "a list becomes one comma-separated header" do
      client = Client.new(beta: ["files-api-2025-04-14", "fast-mode-2026-02-01"])

      assert header(client, "anthropic-beta") == "files-api-2025-04-14,fast-mode-2026-02-01"
    end

    test "a single feature can be given as a string" do
      assert header(Client.new(beta: "files-api-2025-04-14"), "anthropic-beta") ==
               "files-api-2025-04-14"
    end

    test "comes from application config" do
      Application.put_env(:claudex, :beta, ["fast-mode-2026-02-01"])

      assert header(Client.new(), "anthropic-beta") == "fast-mode-2026-02-01"
    end

    test "sits alongside the headers Claudex always sends" do
      client = Client.new(beta: "fast-mode-2026-02-01")

      assert header(client, "x-api-key") == "sk-ant-test"
      assert header(client, "anthropic-version") == "2023-06-01"
      assert header(client, "anthropic-beta") == "fast-mode-2026-02-01"
    end
  end

  describe "reaching the request Req will run" do
    setup do
      Application.put_env(:claudex, :api_key, "sk-ant-test")
    end

    # The struct fields are a copy; these are the values that decide behaviour.
    test "configured settings are on the Req request, not just the struct" do
      Application.put_env(:claudex, :base_url, "https://proxy.internal")
      Application.put_env(:claudex, :max_retries, 5)
      Application.put_env(:claudex, :receive_timeout, 1_000)
      Application.put_env(:claudex, :connect_timeout, 250)

      client = Client.new()

      assert client.req.options[:base_url] == "https://proxy.internal"
      assert client.req.options[:max_retries] == 5
      assert client.req.options[:receive_timeout] == 1_000
      assert client.req.options[:connect_options][:timeout] == 250
    end

    test "an explicit req_options replaces the configured one rather than merging" do
      Application.put_env(:claudex, :req_options, receive_timeout: 111, decode_body: false)

      client = Client.new(req_options: [decode_body: true])

      assert client.req.options[:decode_body] == true
      refute client.req.options[:receive_timeout] == 111
    end

    test "an explicit beta replaces the configured one" do
      Application.put_env(:claudex, :beta, ["from-config"])

      assert header(Client.new(beta: ["explicit"]), "anthropic-beta") == "explicit"
    end

    test "an empty configured beta sends no header" do
      Application.put_env(:claudex, :beta, [])

      assert header(Client.new(), "anthropic-beta") == nil
    end

    test "a header in configured req_options still overrides the default it names" do
      Application.put_env(:claudex, :req_options, headers: [{"anthropic-version", "2024-01-01"}])

      client = Client.new()

      assert header(client, "anthropic-version") == "2024-01-01"
      assert header(client, "x-api-key") == "sk-ant-test"
    end
  end

  describe "applied to a real request" do
    @message %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => [%{"type" => "text", "text" => "hi"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    defp params do
      %{model: "claude-haiku-4-5", max_tokens: 16, messages: [Message.user("hi")]}
    end

    test "a client built entirely from config talks to the configured host with its headers" do
      parent = self()

      Application.put_env(:claudex, :api_key, "sk-ant-configured")
      Application.put_env(:claudex, :base_url, "https://proxy.internal")
      Application.put_env(:claudex, :beta, ["files-api-2025-04-14", "fast-mode-2026-02-01"])
      Application.put_env(:claudex, :req_options, plug: {Req.Test, __MODULE__})

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:request, conn.host, conn.req_headers})

        Req.Test.json(conn, @message)
      end)

      assert {:ok, _message} = Messages.create(Client.new(), params())

      assert_received {:request, host, headers}
      assert host == "proxy.internal"
      assert {"x-api-key", "sk-ant-configured"} in headers
      assert {"anthropic-beta", "files-api-2025-04-14,fast-mode-2026-02-01"} in headers
    end

    test "a configured max_retries actually retries" do
      Application.put_env(:claudex, :api_key, "sk-ant-test")
      Application.put_env(:claudex, :max_retries, 2)

      Application.put_env(:claudex, :req_options,
        plug: {Req.Test, __MODULE__},
        retry_delay: 0,
        retry_log_level: false
      )

      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, @message) end)

      assert {:ok, _message} = Messages.create(Client.new(), params())
    end

    test "a configured max_retries of 0 gives up on the first failure" do
      parent = self()

      Application.put_env(:claudex, :api_key, "sk-ant-test")
      Application.put_env(:claudex, :max_retries, 0)

      Application.put_env(:claudex, :req_options,
        plug: {Req.Test, __MODULE__},
        retry_delay: 0,
        retry_log_level: false
      )

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, :attempt)

        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert {:error, %Claudex.Error{status: 503}} = Messages.create(Client.new(), params())

      assert_received :attempt
      refute_received :attempt
    end
  end

  describe "build/1" do
    test "answers with a client when a key is configured" do
      assert {:ok, %Client{}} = Client.build(api_key: "sk-ant-explicit")
    end

    test "answers with an error rather than raising when none is" do
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:claudex, :api_key)

      assert Client.build() == {:error, :missing_api_key}
    end

    test "reads the same config new/1 does" do
      Application.put_env(:claudex, :api_key, "sk-ant-from-config")

      assert {:ok, client} = Client.build(base_url: "https://example.test")
      assert client.api_key == "sk-ant-from-config"
      assert client.base_url == "https://example.test"
    end
  end
end
