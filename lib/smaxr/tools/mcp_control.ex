defmodule Smaxr.Tools.MCPControl do
  @moduledoc """
  LLM-controllable MCP server management tool.

  Lets the LLM list, enable, disable, restart MCP servers, and search/list
  individual tools across all servers.

  Usage from LLM:
    mcp_control(action: "list")
    mcp_control(action: "enable", server: "filesystem")
    mcp_control(action: "disable", server: "filesystem")
    mcp_control(action: "restart", server: "filesystem")
    mcp_control(action: "search", query: "read")
    mcp_control(action: "tools", server: "filesystem")
  """

  @behaviour Smaxr.Tool

  @impl true
  def name, do: "mcp_control"

  @impl true
  def description, do: "Manage MCP servers: list/enable/disable/restart/search/list_tools."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          enum: ["list", "enable", "disable", "restart", "search", "tools"],
          description: "Action to perform"
        },
        server: %{
          type: :string,
          description: "Server name (required for enable/disable/restart/tools)"
        },
        query: %{
          type: :string,
          description: "Search query (required for search action)"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def call(%{"action" => action} = args) do
    case action do
      "list" ->
        servers = Smaxr.MCP.list_servers()
        lines =
          Enum.map(servers, fn s ->
            status = if s.running, do: "🟢", else: "🔴"
            "#{status} #{s.name} (#{s.tool_count} tools)"
          end)

        {:ok, Enum.join(lines, "\n")}

      "enable" ->
        server = args["server"]
        if server do
          case Smaxr.MCP.enable(server) do
            :ok -> {:ok, "#{server} enabled"}
            {:error, err} -> {:error, err}
          end
        else
          {:error, "mcp_control: 'server' argument required for enable"}
        end

      "disable" ->
        server = args["server"]
        if server do
          case Smaxr.MCP.disable(server) do
            :ok -> {:ok, "#{server} disabled"}
            {:error, err} -> {:error, err}
          end
        else
          {:error, "mcp_control: 'server' argument required for disable"}
        end

      "restart" ->
        server = args["server"]
        if server do
          case Smaxr.MCP.restart(server) do
            :ok -> {:ok, "#{server} restarted"}
            {:error, err} -> {:error, err}
          end
        else
          {:error, "mcp_control: 'server' argument required for restart"}
        end

      "search" ->
        query = args["query"] || ""
        results = Smaxr.MCP.search_tools(query)

        if results == [] do
          {:ok, "no tools matching '#{query}'"}
        else
          lines =
            Enum.map(results, fn t ->
              "  #{t.server}:#{t.name} — #{t.description}"
            end)

          {:ok, "tools matching '#{query}':\n#{Enum.join(lines, "\n")}"}
        end

      "tools" ->
        server = args["server"]
        if server do
          tools = Smaxr.MCP.list_tools(server)
          lines = Enum.map(tools, fn t -> "  #{t.name} — #{t.description}" end)
          {:ok, "tools on #{server}:\n#{Enum.join(lines, "\n")}"}
        else
          {:error, "mcp_control: 'server' argument required for tools"}
        end
    end
  end

  def call(_), do: {:error, "mcp_control: missing 'action' argument"}
end
