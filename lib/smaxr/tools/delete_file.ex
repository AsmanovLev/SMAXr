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
  def call(%{"path" => path}) do
    File.rm_rf(path)
    {:ok, "deleted #{path}"}
  end

  def call(_), do: {:error, "missing 'path' argument"}
end
