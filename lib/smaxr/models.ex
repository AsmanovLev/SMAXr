defmodule Smaxr.Models do
  @moduledoc """
  Model registry and cache for the upstream OpenAI-compatible gateway.

  Fetches the available models from `GET /v1/models` once at boot, caches
  them in an ETS table, and exposes a small API:

      Smaxr.Models.list()           # all known models, freshest available
      Smaxr.Models.list!()          # force refresh, then return list
      Smaxr.Models.refresh()        # async refresh
      Smaxr.Models.lookup(id)       # exact match by id, or nil
      Smaxr.Models.find(query)      # fuzzy by id substring / index / family
      Smaxr.Models.valid?(id)       # is id in the known set?
      Smaxr.Models.current()        # current default from app env
      Smaxr.Models.set_current(id)  # update :smaxr, :default_model

  The cache TTL is 10 minutes by default; forced refresh is always cheap
  (one HTTP call) and runs through `Req` with the same auth as
  `Smaxr.LLM.OpenAI`.
  """

  use GenServer
  require Logger

  alias Smaxr.LLM.OpenAI, as: LLM

  @table :smaxr_models
  @meta_table :smaxr_models_meta
  @ttl_ms 10 * 60 * 1000
  @refresh_timeout 10_000

  ## Public API

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec list() :: [%{id: String.t(), owned_by: String.t(), source: atom()}]
  def list do
    if stale?() do
      refresh()
    end

    read_table()
  end

  @spec list!() :: [%{id: String.t(), owned_by: String.t(), source: atom()}]
  def list! do
    :ok = refresh()
    read_table()
  end

  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    GenServer.call(__MODULE__, :refresh, @refresh_timeout)
  end

  @spec lookup(String.t()) :: %{id: String.t(), owned_by: String.t()} | nil
  def lookup(id) when is_binary(id) do
    Enum.find(list(), fn m -> m.id == id end)
  end

  @spec valid?(String.t()) :: boolean()
  def valid?(id) when is_binary(id) do
    Enum.any?(list(), fn m -> m.id == id end)
  end

  @doc """
  Find a model by:
    * exact id                  -> the model
    * index in the list (1..N)   -> model at that position
    * substring / family prefix  -> the first match
    * "current" or nil/""       -> current default
  """
  @spec find(String.t() | nil) :: %{id: String.t(), owned_by: String.t()} | nil
  def find(query) do
    models = list()
    q = (query || "") |> to_string() |> String.trim()

    cond do
      q == "" or String.downcase(q) in ~w(current default) ->
        find_by_id(models, current())

      true ->
        # 1. exact id
        case find_by_id(models, q) do
          nil ->
            # 2. numeric index
            case Integer.parse(q) do
              {n, ""} when n >= 1 and n <= length(models) -> Enum.at(models, n - 1)
              _ ->
                # 3. family / substring (case-insensitive)
                Enum.find(models, fn m ->
                  String.contains?(String.downcase(m.id), String.downcase(q))
                end)
            end

          m ->
            m
        end
    end
  end

  @spec current() :: String.t()
  def current do
    Application.get_env(:smaxr, :default_model, "minimax-m3")
  end

  @spec set_current(String.t()) :: :ok | {:error, :unknown_model}
  def set_current(id) when is_binary(id) do
    cond do
      valid?(id) ->
        Application.put_env(:smaxr, :default_model, id)
        :ok

      true ->
        case find(id) do
          %{id: real_id} -> set_current(real_id)
          nil -> {:error, :unknown_model}
        end
    end
  end

  ## GenServer

  @impl true
  def init(:ok) do
    ensure_table()
    # Eagerly warm the cache on boot, but never block the supervisor.
    send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    case fetch() do
      {:ok, models} ->
        write_table(models)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Smaxr.Models] initial fetch failed: #{inspect(reason)}")
        # Seed with at least the current default so /model still works.
        write_table([%{id: current(), owned_by: "fallback", source: :seed}])
        # Retry in 30 s
        Process.send_after(self(), :refresh, 30_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case fetch() do
      {:ok, models} ->
        write_table(models)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  ## Internals

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    end

    if :ets.whereis(@meta_table) == :undefined do
      :ets.new(@meta_table, [:set, :named_table, :public, read_concurrency: true])
    end
  end

  defp write_table(models) do
    ensure_table()
    :ets.delete_all_objects(@table)

    Enum.each(models, fn m ->
      :ets.insert(@table, {m.id, m})
    end)

    :ets.insert(@meta_table, {:fetched_at, System.monotonic_time(:millisecond)})
  end

  defp read_table do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, m} -> m end)
  end

  defp stale? do
    case :ets.whereis(@table) do
      :undefined -> true
      _ -> ts_stale?()
    end
  end

  defp ts_stale? do
    case :ets.whereis(@meta_table) do
      :undefined -> true
      _ -> read_meta() |> compute_stale()
    end
  end

  defp read_meta do
    case :ets.lookup(@meta_table, :fetched_at) do
      [{:fetched_at, ts}] -> ts
      _ -> 0
    end
  end

  defp compute_stale(0), do: true

  defp compute_stale(ts) do
    System.monotonic_time(:millisecond) - ts > @ttl_ms
  end

  defp fetch do
    base_url = Application.get_env(LLM, :base_url, "https://opencode.ai/zen/go/v1")
    api_key = Application.get_env(LLM, :api_key, "")
    url = "#{base_url}/models"

    auth_header =
      if api_key != "" do
        [{"Authorization", "Bearer #{api_key}"}]
      else
        []
      end

    headers = [{"Content-Type", "application/json"}] ++ auth_header

    case Req.get(url, headers: headers, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        models =
          Enum.map(data, fn m ->
            %{
              id: m["id"],
              owned_by: m["owned_by"] || "unknown",
              source: :upstream
            }
          end)

        # Make sure current default is present even if upstream doesn't list it
        models = ensure_current_present(models)
        {:ok, models}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_current_present(models) do
    cur = current()

    if Enum.any?(models, fn m -> m.id == cur end) do
      models
    else
      models ++ [%{id: cur, owned_by: "fallback", source: :local_default}]
    end
  end

  defp find_by_id(models, id) do
    Enum.find(models, fn m -> m.id == id end)
  end
end
