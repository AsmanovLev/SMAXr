defmodule Smaxr.Tools.ApplyPatch do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description, do:
    "Recompile and reload a .ex file in the running BEAM. Use after edit_file/write_file " <>
      "to make the change live (the source change is harmless without this). Returns the " <>
      "list of modules that were reloaded. Path is relative to the project root or absolute."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Path to .ex file to reload"}
      },
      required: ["path"]
    }
  end

  @impl true
  def call(%{"path" => path} = args) do
    with {:ok, abs_path} <- Smaxr.Util.guard_path(path, args["_workdir"]) do
      abs_path = resolve(abs_path)

      cond do
        not File.exists?(abs_path) ->
          {:error, "file not found: #{abs_path}"}

        not String.ends_with?(abs_path, ".ex") ->
          {:error, "apply_patch only reloads .ex files, got: #{abs_path}"}

        true ->
          reload(abs_path)
      end
    end
  end

  defp resolve(path) do
    cond do
      Path.type(path) == :absolute -> path
      true -> Path.join(File.cwd!(), path)
    end
  end

  # Drop the file from the code cache, then re-compile it. We use
  # Code.compile_file/1 (not require_file) because it always re-runs
  # the compiler and surfaces a useful list of returned modules.
  defp reload(abs_path) do
    try do
      Code.unrequire_files([abs_path])
      Code.compile_file(abs_path)
    rescue
      e ->
        {:error, "reload failed: #{Exception.message(e)}"}
    else
      modules ->
        names =
          modules
          |> Enum.map(fn
            {mod, _beam} -> inspect(mod)
            mod when is_atom(mod) -> inspect(mod)
          end)
          |> Enum.uniq()

        {:ok,
         """
         reloaded #{abs_path}
         modules: #{Enum.join(names, ", ")}
         note: hot code replacement — same module names, new bodies.
         Restarting the BEAM is still the only way to change supervisor children.
         """}
    end
  end
end
