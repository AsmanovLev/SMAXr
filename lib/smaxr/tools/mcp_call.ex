defmodule Smaxr.Tools.MCPCall do
  @moduledoc """
  Calls a tool on an MCP server. The LLM discovers available tools
  via `mcp_control(action: "tools", server: "...")` or
  `mcp_control(action: "search", query: "...")`.

  Usage from LLM:
    mcp_call(server: "filesystem", tool: "read_file", arguments: {path: "/etc/hosts"})
  """

  @behaviour Smaxr.Tool

  @impl true
  def name, do: "mcp_call"

  @impl true
  def description, do: "Call a tool on an MCP server. Use mcp_control first to discover available tools."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        server: %{type: :string, description: "MCP server name"},
        tool: %{type: :string, description: "Tool name on that server"},
        arguments: %{type: :object, description: "Tool arguments (key-value pairs)"}
      },
      required: ["server", "tool"]
    }
  end

  @impl true
  def call(%{"server" => server, "tool" => tool} = args) do
    arguments = Map.get(args, "arguments", %{})
    Smaxr.MCP.call_tool(server, tool, arguments)
  end

  def call(_), do: {:error, "mcp_call: missing 'server' or 'tool' argument"}
end
