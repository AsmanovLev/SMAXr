defmodule Smaxr.Tools.FileInfo do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "file_info"

  @impl true
  def description, do: "Get metadata about a file or directory."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path"}
      },
      required: ["path"]
    }
  end

  @impl true
  def call(%{"path" => path} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      case File.stat(abs_path) do
        {:ok, stat} ->
          info = """
          path: #{abs_path}
          size: #{stat.size}
          type: #{if File.dir?(abs_path), do: "dir", else: "file"}
          modified: #{format_time(stat.mtime)}
          """

          {:ok, info}

        {:error, reason} ->
          {:error, "file_info: #{reason}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'path' argument"}

  defp format_time(stat_time) do
    # stat_time is an Erlang tuple {{Y,M,D},{H,Min,S}} or a NaiveDateTime
    case stat_time do
      {{y, m, d}, {h, min, s}} ->
        "#{y}-#{pad(m)}-#{pad(d)} #{pad(h)}:#{pad(min)}:#{pad(s)}"

      other ->
        inspect(other)
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
