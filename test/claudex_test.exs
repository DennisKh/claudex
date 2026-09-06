defmodule ClaudexTest do
  use ExUnit.Case, async: true

  test "new/1 builds a client" do
    client = Claudex.new(api_key: "sk-ant-test")

    assert %Claudex.Client{api_key: "sk-ant-test"} = client
  end
end
