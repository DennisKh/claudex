defmodule Claudex.PageTest do
  use ExUnit.Case, async: true

  alias Claudex.{Client, Error, Files, Messages, Models, Page}

  defp client do
    Client.new(
      api_key: "sk-ant-test",
      max_retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  # Each call answers with the next page in the list, and reports the query it
  # was given, so the cursor the stream threaded is visible.
  defp respond_with(pages) do
    {:ok, remaining} = Agent.start_link(fn -> pages end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:query, conn.query_params})

      Req.Test.json(conn, Agent.get_and_update(remaining, fn [head | tail] -> {head, tail} end))
    end)
  end

  defp model(id), do: %{"id" => id, "type" => "model", "display_name" => id}

  defp file(id),
    do: %{"id" => id, "type" => "file", "filename" => id, "mime_type" => "text/plain"}

  test "stream!/2 walks id cursors until has_more stops" do
    respond_with([
      %{"data" => [model("a"), model("b")], "has_more" => true, "last_id" => "b"},
      %{"data" => [model("c")], "has_more" => false, "last_id" => "c"}
    ])

    assert client() |> Models.stream!() |> Enum.map(& &1.id) == ["a", "b", "c"]

    assert_received {:query, first}
    refute Map.has_key?(first, "after_id")

    assert_received {:query, %{"after_id" => "b"}}
    refute_received {:query, _third}
  end

  test "stream!/2 walks the opaque cursor until it runs out" do
    respond_with([
      %{"data" => [file("f1")], "next_page" => "cursor_2"},
      %{"data" => [file("f2")], "next_page" => nil}
    ])

    assert client() |> Files.stream!() |> Enum.map(& &1.id) == ["f1", "f2"]

    assert_received {:query, _first}
    assert_received {:query, %{"page" => "cursor_2"}}
  end

  test "stream!/2 stops early, and asks for nothing it doesn't need" do
    respond_with([%{"data" => [model("a"), model("b")], "has_more" => true, "last_id" => "b"}])

    assert client() |> Models.stream!() |> Enum.take(1) |> Enum.map(& &1.id) == ["a"]

    assert_received {:query, _first}
    refute_received {:query, _second}
  end

  test "stream!/2 passes its options on, page after page" do
    respond_with([
      %{"data" => [model("a")], "has_more" => true, "last_id" => "a"},
      %{"data" => [model("b")], "has_more" => false}
    ])

    assert client() |> Models.stream!(limit: 1) |> Enum.to_list() |> length() == 2

    assert_received {:query, %{"limit" => "1"}}
    assert_received {:query, %{"limit" => "1", "after_id" => "a"}}
  end

  test "stream!/2 raises when a page fails" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"type" => "error", "error" => %{"type" => "rate_limit_error"}})
    end)

    assert_raise Error, fn -> client() |> Messages.Batches.stream!() |> Enum.to_list() end
  end

  test "a page naming no cursor is the last one" do
    respond_with([%{"data" => [model("a")], "has_more" => true}])

    assert client() |> Models.stream!() |> Enum.map(& &1.id) == ["a"]
  end

  test "decode/2 keeps both cursor styles" do
    page = Page.decode(%{"data" => [], "has_more" => false, "last_id" => "x"}, & &1)

    assert page.last_id == "x"
    assert page.next_page == nil
  end
end
