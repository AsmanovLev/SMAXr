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
  def call(%{"path" => path} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      case File.exists?(abs_path) and not File.dir?(abs_path) do
        true ->
          {:ok, "file ready at #{abs_path} (size: #{File.stat!(abs_path).size})"}

        false ->
          {:error, "send_file: file not found or is a directory: #{abs_path}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'path' argument"}
end
