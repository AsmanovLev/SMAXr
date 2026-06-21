defmodule Smaxr.Agent.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  def start_agent(user_id) do
    spec = %{id: user_id, start: {Smaxr.Agent, :start_link, [user_id]}, restart: :transient}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
