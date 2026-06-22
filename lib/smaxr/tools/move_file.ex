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
  def call(%{"source" => src, "destination" => dst} = args) do
    with {:ok, abs_src} <- Smaxr.Util.guard_path(src, args["_workdir"]),
         {:ok, abs_dst} <- Smaxr.Util.guard_path(dst, args["_workdir"]) do
      case File.rename(abs_src, abs_dst) do
        :ok -> {:ok, "moved #{abs_src} -> #{abs_dst}"}
        {:error, reason} -> {:error, "move_file: #{reason}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'source' or 'destination'"}
end
