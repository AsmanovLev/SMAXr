defmodule Smaxr.Tools.WriteFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "write_file"

  @impl true
  def description, do: "Write content to a file (overwrites existing)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the file"},
        content: %{type: :string, description: "Text content to write"}
      },
      required: ["path", "content"]
    }
  end

  @impl true
  def call(args) when is_map(args) do
    path = args["path"] || args["file_path"] || args["filePath"] || args[:path]
    content = args["content"] || args[:content]

    if is_binary(path) and is_binary(content) do
      dir = Path.dirname(path)

      case File.mkdir_p(dir) do
        :ok ->
          case File.write(path, content) do
            :ok -> {:ok, "written to #{path}"}
            {:error, reason} -> {:error, "write_file: #{reason}"}
          end

        {:error, reason} ->
          {:error, "write_file: mkdir_p: #{reason}"}
      end
    else
      {:error, "missing 'path' or 'content'"}
    end
  end
end
