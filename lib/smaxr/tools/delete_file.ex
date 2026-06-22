defmodule Smaxr.Tools.DeleteFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "delete_file"

  @impl true
  def description, do: "Delete a file or empty directory."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the file or empty directory"}
      },
      required: ["path"]
    }
  end

  @impl true
  def call(%{"path" => path} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      File.rm_rf(abs_path)
      {:ok, "deleted #{abs_path}"}
    end
  end

  def call(_), do: {:error, "missing 'path' argument"}
end
