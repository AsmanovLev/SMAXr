defmodule Smaxr.Tools.Grep do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "grep"

  @impl true
  def description, do: "Search for a pattern in files (recursive)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        pattern: %{type: :string, description: "Search pattern (regex)"},
        path: %{type: :string, description: "Directory to search (default: project root)"},
        include: %{type: :string, description: "File pattern to include (e.g. *.ex)"}
      },
      required: ["pattern"]
    }
  end

  @impl true
  def call(%{"pattern" => pattern} = args) do
    search_dir = Map.get(args, "path", ".")

    with {:ok, abs_dir} <- Smaxr.Util.guard_path(search_dir, args["_workdir"]) do
      cmd = "Get-ChildItem -Recurse -File #{abs_dir} | Select-String -Pattern '#{pattern}' | Format-Table -AutoSize"

      case Smaxr.Util.safe_cmd("powershell", ["-Command", cmd]) do
        {:error, reason} ->
          {:error, "grep: #{reason}"}

        {output, _code} ->
          output = String.trim(output)
          if output == "", do: {:ok, "no matches"}, else: {:ok, output}
      end
    end
  end

  def call(_), do: {:error, "missing 'pattern' argument"}
end
