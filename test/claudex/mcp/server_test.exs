defmodule Claudex.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Claudex.MCP.Server

  @server %Server{
    name: "github",
    url: "https://api.githubcopilot.com/mcp/",
    authorization_token: "ghp_secret_value"
  }

  test "inspect/1 prints the server without its token" do
    printed = inspect(@server)

    refute printed =~ "ghp_secret_value"
    assert printed =~ "github"
    assert printed =~ "api.githubcopilot.com"
  end

  test "the token stays hidden however the struct is nested" do
    refute inspect(%{mcp_servers: [@server]}) =~ "ghp_secret_value"
  end

  test "to_param/1 builds the map the API takes" do
    assert Server.to_param(@server) == %{
             type: "url",
             name: "github",
             url: "https://api.githubcopilot.com/mcp/",
             authorization_token: "ghp_secret_value"
           }
  end

  test "to_param/1 leaves out a token that isn't there" do
    param = Server.to_param(%Server{name: "deepwiki", url: "https://mcp.deepwiki.com/mcp"})

    refute Map.has_key?(param, :authorization_token)
    assert param == %{type: "url", name: "deepwiki", url: "https://mcp.deepwiki.com/mcp"}
  end

  test "to_param/1 passes a hand-written map through" do
    server = %{type: "url", name: "github", url: "https://api.githubcopilot.com/mcp/"}

    assert Server.to_param(server) == server
  end

  test "name and url are required" do
    assert_raise ArgumentError, fn -> struct!(Server, url: "https://example.com/mcp") end
  end
end
