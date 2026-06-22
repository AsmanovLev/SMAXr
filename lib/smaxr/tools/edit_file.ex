defmodule Smaxr.Tools.EditFile do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "edit_file"

  @impl true
  def description, do: "Edit a file by replacing exact text with new text."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the file"},
        old: %{type: :string, description: "Exact text to replace"},
        new: %{type: :string, description: "Replacement text"}
      },
      required: ["path", "old", "new"]
    }
  end

  @impl true
  def call(%{"path" => path, "old" => old, "new" => new} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      case File.read(abs_path) do
        {:ok, content} ->
          if String.contains?(content, old) do
            new_content = String.replace(content, old, new)

            case File.write(abs_path, new_content) do
              :ok -> {:ok, "edited #{abs_path} (#{String.length(new)} chars replaced)"}
              {:error, reason} -> {:error, "edit_file: write: #{reason}"}
            end
          else
            {:error, "edit_file: old string not found in #{abs_path}"}
          end

        {:error, reason} ->
          {:error, "edit_file: read: #{reason}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'path', 'old', or 'new'"}
end
