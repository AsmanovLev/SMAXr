defmodule Smaxr.Store do
  @table :smaxr_store

  def open do
    path = Path.join(data_dir(), "store.dets") |> Path.absname()
    path |> Path.dirname() |> File.mkdir_p!()

    case :dets.open_file(@table, file: String.to_charlist(path)) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Store open failed: #{reason}"
    end
  end

  def close do
    :dets.close(@table)
  end

  def get_active(chat_id) do
    case :dets.lookup(@table, {:active, chat_id}) do
      [{_, name}] -> {:ok, name}
      [] -> {:error, :not_found}
    end
  end

  def set_active(chat_id, name) do
    :ok = :dets.insert(@table, {{:active, chat_id}, name})
    :ok = :dets.sync(@table)
  end

  def get_session(chat_id, name) do
    case :dets.match(@table, {{:session, chat_id, name}, :"$1"}) do
      [[data]] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  def save_session(chat_id, name, data) do
    data = Map.put(data, :updated_at, System.system_time(:second))
    :ok = :dets.insert(@table, {{:session, chat_id, name}, data})
    :ok = :dets.sync(@table)
  end

  def list_sessions(chat_id) do
    :dets.match(@table, {{:session, chat_id, :"$1"}, :"$2"})
    |> Enum.map(fn [name, data] ->
      %{
        name: name,
        message_count: length(Map.get(data, :messages, [])),
        workdir: Map.get(data, :workdir),
        updated_at: Map.get(data, :updated_at, 0)
      }
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  def delete_session(chat_id, name) do
    :dets.delete(@table, {{:session, chat_id, name}})
    :dets.sync(@table)
  end

  def clear do
    :dets.delete_all_objects(@table)
    :dets.sync(@table)
  end

  def store_open? do
    case :dets.info(@table) do
      :undefined -> false
      _ -> true
    end
  end

  defp data_dir do
    Application.get_env(:smaxr, :data_dir, "priv/smaxr")
  end
end
