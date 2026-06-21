defmodule Smaxr.Tools.MoveFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "move_file"

  @impl true
  def description, do: "Move or rename a file or directory."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        source: %{type: :string, description: "Current path"},
        destination: %{type: :string, description: "New path"}
      },
      required: ["source", "destination"]
    }
  end

  @impl true
  def call(%{"source" => src, "destination" => dst}) do
    case File.rename(src, dst) do
      :ok -> {:ok, "moved #{src} -> #{dst}"}
      {:error, reason} -> {:error, "move_file: #{reason}"}
    end
  end

  def call(_), do: {:error, "missing 'source' or 'destination'"}
end
