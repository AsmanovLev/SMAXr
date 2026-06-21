defmodule Smaxr.Router do
  @moduledoc """
  Subscribes to Konsolidator's incoming events and dispatches to the
  per-user Agent.

  The Agent is started under `Smaxr.Agent.Supervisor` (DynamicSupervisor).
  The first incoming message for a user_id starts the agent; subsequent
  messages are cast to it.
  """

  use GenServer

  alias Konsolidator.Router, as: KonsRouter
  alias Smaxr.Agent.Supervisor, as: AgentSupervisor
  alias Smaxr.Agent

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ok = KonsRouter.subscribe_incoming()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:incoming, payload}, state) do
    case payload do
      %{source: source, user_id: user_id} = p when not is_nil(user_id) ->
        {:ok, _pid} = ensure_agent(user_id)
        Agent.handle_incoming(user_id, source, p)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_agent(user_id) do
    case Agent.whereis(user_id) do
      nil ->
        AgentSupervisor.start_agent(user_id)

      pid ->
        {:ok, pid}
    end
  end
end
