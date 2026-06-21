defmodule Smaxr.Tools.SendFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "send_file"

  @impl true
  def description, do: "Send a file to the user (via the active messenger adapter)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the file"},
        caption: %{type: :string, description: "Optional caption"}
      },
      required: ["path"]
    }
  end

  @impl true
  def call(%{"path" => path}) do
    case File.exists?(path) and not File.dir?(path) do
      true ->
        {:ok, "file ready at #{path} (size: #{File.stat!(path).size})"}

      false ->
        {:error, "send_file: file not found or is a directory: #{path}"}
    end
  end

  def call(_), do: {:error, "missing 'path' argument"}
end
