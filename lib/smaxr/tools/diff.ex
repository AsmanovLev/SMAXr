defmodule Smaxr.Tools.Diff do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "diff"

  @impl true
  def description, do: "Show differences between two files (like shell diff)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        file_a: %{type: :string, description: "Absolute path to first file"},
        file_b: %{type: :string, description: "Absolute path to second file"}
      },
      required: ["file_a", "file_b"]
    }
  end

  @impl true
  def call(%{"file_a" => a, "file_b" => b}) do
    case Smaxr.Util.safe_cmd("powershell", ["-Command", "diff (Get-Content #{a}) (Get-Content #{b})"]) do
      {:error, reason} ->
        {:error, "diff: #{reason}"}

      {output, _code} ->
        output = String.trim(output)

        if output == "" do
          {:ok, "files are identical"}
        else
          {:ok, output}
        end
    end
  end

  def call(_), do: {:error, "missing 'file_a' or 'file_b'"}
end
