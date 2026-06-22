defmodule Smaxr.Tools.ListDir do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "list_dir"

  @impl true
  def description, do: "List files and directories in a directory."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the directory"}
      },
      required: ["path"]
    }
  end

  @impl true
  def call(%{"path" => path} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      case File.ls(abs_path) do
        {:ok, entries} ->
          summary =
            entries
            |> Enum.map(fn name ->
              full = Path.join(abs_path, name)
              type = if File.dir?(full), do: "dir", else: "file"
              "#{name} (#{type})"
            end)
            |> Enum.join("\n")

          {:ok, summary}

        {:error, reason} ->
          {:error, "list_dir: #{reason}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'path' argument"}
end
