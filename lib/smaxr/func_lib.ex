defmodule Smaxr.FuncLib do
  @moduledoc """
  Persistent function library. Helper functions that the agent creates
  at runtime are stored here and survive across conversations.

  The agent can define helpers:

      Smaxr.FuncLib.set(:format_date, fn dt ->
        Calendar.strftime(dt, "%Y-%m-%d")
      end)

  And call them later:

      Smaxr.FuncLib.get(:format_date).(DateTime.utc_now())

  Helpers are stored in an ETS table and persist for the lifetime of
  the BEAM node. In future they will be serialized to disk.
  """

  @ets_table :smaxr_func_lib

  @doc false
  def ensure_table do
    if :ets.info(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  @doc "Store a helper function by name."
  def set(name, fun) when is_atom(name) and is_function(fun) do
    ensure_table()
    :ets.insert(@ets_table, {name, fun})
    :ok
  end

  @doc "Retrieve a helper function by name. Returns nil if not found."
  def get(name) when is_atom(name) do
    ensure_table()

    case :ets.lookup(@ets_table, name) do
      [{^name, fun}] -> fun
      _ -> nil
    end
  end

  @doc "Delete a helper."
  def delete(name) when is_atom(name) do
    ensure_table()
    :ets.delete(@ets_table, name)
    :ok
  end

  @doc "List all helper names."
  def keys do
    ensure_table()
    :ets.tab2list(@ets_table) |> Enum.map(fn {k, _} -> k end)
  end

  @doc "List all helpers and their types."
  def list do
    ensure_table()

    :ets.tab2list(@ets_table)
    |> Enum.map(fn {name, fun} -> {name, inspect(:erlang.fun_info(fun)[:arity])} end)
    |> Enum.into(%{})
  end
end
