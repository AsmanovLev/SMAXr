defmodule Smaxr.Tools.FindFiles do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "find_files"

  @impl true
  def description, do: "Find files by glob pattern (recursive)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        pattern: %{type: :string, description: "Glob pattern (e.g. **/*.ex)"},
        path: %{type: :string, description: "Root path (default: .)"}
      },
      required: ["pattern"]
    }
  end

  @impl true
  def call(%{"pattern" => pattern} = args) do
    search_dir = Map.get(args, "path", ".")
    pattern_ps = pattern |> String.replace("*", "`*")
    cmd = "Get-ChildItem -Path #{search_dir} -Recurse -Filter #{pattern_ps} | Select-Object -ExpandProperty FullName"

    case Smaxr.Util.safe_cmd("powershell", ["-Command", cmd]) do
      {:error, reason} ->
        {:error, "find_files: #{reason}"}

      {output, _code} ->
        output = String.trim(output)
        if output == "", do: {:ok, "no files found"}, else: {:ok, output}
    end
  end

  def call(_), do: {:error, "missing 'pattern' argument"}
end
