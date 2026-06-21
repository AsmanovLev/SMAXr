defmodule Smaxr.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Per-agent registry.
        {Registry, keys: :duplicate, name: Smaxr.Registry},
        # Eval sandbox runner.
        {Task.Supervisor, name: Smaxr.EvalSupervisor},
        # MCP server manager + dynamic supervisor.
        Smaxr.MCP.Supervisor,
        {Smaxr.MCP, []},
        # Model registry — warms the upstream model list on boot.
        Smaxr.Models,
        # Konsolidator is started as a separate application.
        Smaxr.Agent.Supervisor,
        Smaxr.Router
      ]

    opts = [strategy: :one_for_one, name: Smaxr.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
