defmodule Smaxr.MCP do
  @moduledoc """
  MCP (Model Context Protocol) Manager.

  Manages MCP server processes (JSON-RPC over stdio). The LLM can control
  servers via `mcp_control` tool: enable/disable/restart/search/list.

  Each server registers its tools in ETS table `:mcp_tools`:
    `{server_name, tool_name} => %{description, input_schema, enabled}`

  ## Config in config.exs:

      config :smaxr, :mcp_servers, [
        %{
          name: "filesystem",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
          env: %{},
          disabled: false
        }
      ]
  """

  use GenServer
  require Logger

  defstruct servers: []

  @ets_table :mcp_tools

  # ── Public API ──────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def list_servers do
    GenServer.call(__MODULE__, :list_servers)
  end

  def list_tools(server_name) do
    :ets.match_object(@ets_table, {{server_name, :_}, :_})
    |> Enum.map(fn {{_s, t}, v} -> Map.put(v, :name, t) end)
  end

  def search_tools(query) do
    q = String.downcase(query)

    :ets.tab2list(@ets_table)
    |> Enum.filter(fn {{_s, t}, v} ->
      String.contains?(String.downcase(t), q) or
        String.contains?(String.downcase(v.description || ""), q)
    end)
    |> Enum.map(fn {{s, t}, v} -> Map.put(v, :name, t) |> Map.put(:server, s) end)
  end

  def call_tool(server_name, tool_name, args) do
    server_pid = :global.whereis_name({:mcp_server, server_name})

    if server_pid do
      GenServer.call(server_pid, {:call, tool_name, args}, 60_000)
    else
      {:error, "MCP server '#{server_name}' not running"}
    end
  end

  def enable(server_name) do
    GenServer.call(__MODULE__, {:set_enabled, server_name, true})
  end

  def disable(server_name) do
    GenServer.call(__MODULE__, {:set_enabled, server_name, false})
  end

  def restart(server_name) do
    GenServer.call(__MODULE__, {:restart, server_name})
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    servers = Application.get_env(:smaxr, :mcp_servers, [])
    state = %__MODULE__{}

    state = Enum.reduce(servers, state, fn cfg, acc ->
      if cfg[:disabled] do
        acc
      else
        start_server(acc, cfg)
      end
    end)

    {:ok, state}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    # Collect state from each running server process (via global name)
    statuses =
      state.servers
      |> Enum.map(fn name ->
        pid = :global.whereis_name({:mcp_server, name})
        tools = list_tools(name)
        %{
          name: name,
          running: is_pid(pid) and Process.alive?(pid),
          tool_count: length(tools),
          tools: Enum.map(tools, & &1.name)
        }
      end)

    {:reply, statuses, state}
  end

  def handle_call({:set_enabled, name, enabled}, _from, state) do
    if enabled do
      cfg = find_config(name)
      if cfg, do: start_server(state, cfg), else: {:reply, {:error, "not found"}, state}
    else
      stop_server(state, name)
    end
  end

  def handle_call({:restart, name}, _from, state) do
    state = stop_server(state, name)
    cfg = find_config(name)
    if cfg, do: {:reply, :ok, start_server(state, cfg)}, else: {:reply, {:error, "not found"}, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp start_server(state, cfg) do
    name = cfg.name

    case DynamicSupervisor.start_child(Smaxr.MCP.Supervisor, {
      Smaxr.MCP.Server, {name, cfg.command, cfg.args || [], cfg.env || %{}, @ets_table}
    }) do
      {:ok, _pid} ->
        %{state | servers: [name | state.servers]}

      {:error, reason} ->
        Logger.warning("[MCP] failed to start server #{name}: #{inspect(reason)}")
        state
    end
  end

  defp stop_server(state, name) do
    pid = :global.whereis_name({:mcp_server, name})
    if pid, do: DynamicSupervisor.terminate_child(Smaxr.MCP.Supervisor, pid)

    # Remove tools from ETS
    :ets.match_delete(@ets_table, {{name, :_}, :_})

    %{state | servers: List.delete(state.servers, name)}
  end

  defp find_config(name) do
    Application.get_env(:smaxr, :mcp_servers, [])
    |> Enum.find(fn s -> s.name == name end)
  end
end
