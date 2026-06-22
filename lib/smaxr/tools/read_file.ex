defmodule Smaxr.Tools.ReadFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read a file (optionally a slice of lines)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the file"},
        offset: %{
          type: :integer,
          description: "Skip first N lines (0-based). Omit to read from start.",
          minimum: 0
        },
        limit: %{
          type: :integer,
          description: "Max number of lines to return. Omit for whole file.",
          minimum: 1
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def call(args) when is_map(args) do
    path = args["path"] || args["file_path"] || args["filePath"] || args[:path]
    offset = args["offset"] || args[:offset] || 0
    limit = args["limit"] || args[:limit]

    if is_binary(path) do
      with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]),
           {:ok, content} <- File.read(abs_path) do
        {:ok, slice(content, offset, limit)}
      else
        {:error, reason} -> {:error, "read_file: #{reason}"}
      end
    else
      {:error, "missing 'path' argument"}
    end
  end

  defp slice(content, 0, nil), do: content
  defp slice(content, offset, nil) do
    content
    |> String.split("\n")
    |> Enum.drop(offset)
    |> Enum.join("\n")
  end
  defp slice(content, 0, limit) do
    content
    |> String.split("\n")
    |> Enum.take(limit)
    |> Enum.join("\n")
  end
  defp slice(content, offset, limit) do
    content
    |> String.split("\n")
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.join("\n")
  end
end
