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

    with {:ok, abs_dir} <- Smaxr.Util.guard_path(search_dir, args["_workdir"]) do
      pattern_ps = pattern |> String.replace("*", "`*")
      cmd = "Get-ChildItem -Path #{abs_dir} -Recurse -Filter #{pattern_ps} | Select-Object -ExpandProperty FullName"

      case Smaxr.Util.safe_cmd("powershell", ["-Command", cmd]) do
        {:error, reason} ->
          {:error, "find_files: #{reason}"}

        {output, _code} ->
          output = String.trim(output)
          if output == "", do: {:ok, "no files found"}, else: {:ok, output}
      end
    end
  end

  def call(_), do: {:error, "missing 'pattern' argument"}
end
