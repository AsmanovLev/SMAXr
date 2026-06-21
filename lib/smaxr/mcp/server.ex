defmodule Smaxr.MCP.Server do
  use GenServer
  require Logger

  defstruct name: nil, port: nil, ets_table: nil, timeout: 30_000

  def start_link({name, command, args, env, ets_table}) do
    GenServer.start_link(__MODULE__, {name, command, args, env, ets_table},
      name: {:global, {:mcp_server, name}}
    )
  end

  @impl true
  def init({name, command, args, env, ets_table}) do
    port = Port.open({:spawn_executable, command},
      [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, :in, :out, {:args, args}])

    for {k, v} <- env, do: Port.command(port, "#{k}=#{v}\n")

    state = %__MODULE__{name: name, port: port, ets_table: ets_table}
    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    case send_request(state, "initialize", %{protocolVersion: "2024-11-05", capabilities: %{}, clientInfo: %{name: "SMAXr", version: "0.1"}}) do
      {:ok, _result} ->
        discover_tools(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("MCP.Server #{state.name}: initialize failed: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:call, tool_name, args}, _from, state) do
    case send_request(state, "tools/call", %{name: tool_name, arguments: args}) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ── JSON-RPC ─────────────────────────────────────────────────────

  defp send_request(state, method, params) do
    id = System.unique_integer([:positive])
    req = %{jsonrpc: "2.0", id: id, method: method, params: params}
    port = state.port
    Port.command(port, Jason.encode!(req) <> "\n")

    receive do
      {^port, {:data, data}} ->
        parse_response(data, id)
    after
      state.timeout ->
        {:error, :timeout}
    end
  end

  defp parse_response(data, expected_id) do
    data
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, :no_response}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => ^expected_id, "result" => r}} -> {:ok, r}
        {:ok, %{"id" => ^expected_id, "error" => err}} -> {:error, err}
        _ -> nil
      end
    end)
  end

  defp discover_tools(state) do
    case send_request(state, "tools/list", %{}) do
      {:ok, %{"tools" => tools}} ->
        for tool <- tools do
          :ets.insert(state.ets_table, {
            {state.name, tool["name"]},
            %{
              server: state.name,
              description: tool["description"] || "",
              input_schema: tool["inputSchema"] || %{},
              enabled: true
            }
          })
        end

        Logger.info("MCP.Server #{state.name}: #{length(tools)} tools discovered")

      other ->
        Logger.warning("MCP.Server #{state.name}: tools/list failed: #{inspect(other)}")
    end
  end
end
