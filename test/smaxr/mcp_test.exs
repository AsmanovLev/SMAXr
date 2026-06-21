defmodule Smaxr.MCPTest do
  use ExUnit.Case, async: false

  alias Smaxr.MCP

  setup do
    # Ensure MCP manager is running (it's started by the app supervision tree)
    if Process.whereis(Smaxr.MCP) do
      :ok
    else
      {:ok, _} = start_supervised({Smaxr.MCP, []})
      :ok
    end
  end

  test "list_servers returns empty list when no servers configured" do
    servers = MCP.list_servers()
    assert is_list(servers)
  end

  test "search_tools returns empty when no tools registered" do
    results = MCP.search_tools("read")
    assert results == []
  end

  test "list_tools returns empty for unknown server" do
    tools = MCP.list_tools("nonexistent")
    assert tools == []
  end

  test "mcp_control tool with list action" do
    {:ok, result} = Smaxr.Tools.MCPControl.call(%{"action" => "list"})
    assert is_binary(result)
  end

  test "mcp_control tool with search action" do
    {:ok, result} = Smaxr.Tools.MCPControl.call(%{"action" => "search", "query" => "read"})
    assert is_binary(result)
  end

  test "mcp_control tool errors on missing server for enable" do
    {:error, _} = Smaxr.Tools.MCPControl.call(%{"action" => "enable"})
  end

  test "mcp_control tool errors on missing action" do
    {:error, _} = Smaxr.Tools.MCPControl.call(%{})
  end

  test "mcp_call tool errors on missing server" do
    {:error, _} = Smaxr.Tools.MCPCall.call(%{"tool" => "read"})
  end
end
