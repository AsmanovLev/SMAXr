defmodule Smaxr do
  @moduledoc """
  SMAXr — agent application entry-point facade.

  The interesting things are in the submodules:
    * `Smaxr.Agent` — per-user GenServer
    * `Smaxr.Agent.Supervisor` — DynamicSupervisor for agents
    * `Smaxr.Router` — incoming-event router
  """

  defdelegate start(type, args), to: Smaxr.Application
end
