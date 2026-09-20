defmodule Claudex.MCP.Server do
  @moduledoc """
  A remote MCP server, for `:mcp_servers` in `Claudex.Messages.create/2`.

      %Claudex.MCP.Server{
        name: "github",
        url: "https://api.githubcopilot.com/mcp/",
        authorization_token: System.fetch_env!("GITHUB_TOKEN")
      }

  Anthropic connects to `url`, so it has to be public HTTPS. A server on
  localhost or inside a private network cannot be reached.

  `name` is what an `mcp_toolset` in `:tools` points at, and what comes back as
  `server_name` on a `Claudex.ContentBlock.MCPToolUse`. `authorization_token`
  is whatever that server's own OAuth or token scheme issues, and `inspect/1`
  leaves it out, so a server in a config or a crash report doesn't print it.

  A plain map works here too.
  """

  @derive {Inspect, except: [:authorization_token]}

  @enforce_keys [:name, :url]
  defstruct [:name, :url, :authorization_token]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          authorization_token: String.t() | nil
        }

  @doc """
  Builds the map the API expects in `mcp_servers`.

  A plain map passes through unchanged. `authorization_token` is left out when
  there isn't one.
  """
  @spec to_param(t() | map()) :: map()
  def to_param(%__MODULE__{} = server) do
    %{type: "url", name: server.name, url: server.url}
    |> put_token(server.authorization_token)
  end

  def to_param(%{} = server), do: server

  defp put_token(param, nil), do: param
  defp put_token(param, token), do: Map.put(param, :authorization_token, token)
end
