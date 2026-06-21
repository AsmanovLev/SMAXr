defmodule Smaxr.Tools.Eval do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "eval"

  @impl true
  def description, do: "Evaluate Elixir code in the running BEAM. You have full access to Smaxr modules, running processes, ETS tables. Can optionally import modules for shorter syntax."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        code: %{type: :string, description: "Elixir code to evaluate (single expression or block)"},
        imports: %{type: :string, description: "Comma-separated modules to import (e.g. Smaxr.Agent,Smaxr.MCP)"}
      },
      required: ["code"]
    }
  end

  @impl true
  def call(%{"code" => code} = args) do
    imports = Map.get(args, "imports", "")
    import_code = build_imports(imports)

    task = Task.Supervisor.async_nolink(Smaxr.EvalSupervisor, fn ->
      run(code, import_code)
    end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, format_result(result)}
      nil -> {:error, "eval timeout (15s)"}
      {:exit, reason} -> {:error, "eval crashed: #{inspect(reason)}"}
    end
  end

  def call(_), do: {:error, "eval: missing 'code' argument"}

  defp run(code, import_code) do
    # Always use Code.eval_string — it auto-loads modules when you
    # write a defmodule. For expressions we wrap in a fn for a clean
    # return value.
    full_code = if has_module_def?(code) do
      "#{import_code}\n#{code}"
    else
      "#{import_code}\nresult = (fn -> #{code} end).()\nresult"
    end

    {result, _bindings} = Code.eval_string(full_code)

    case result do
      {tag, module, beam, _rest} when tag in [:module, :redef] ->
        {:compiled, [{module, beam}]}

      _ ->
        result
    end
  end

  defp has_module_def?(code) do
    # Naive but enough: any top-level defmodule counts. Multiline OK.
    String.match?(code, ~r/^\s*defmodule\s+/m)
  end

  defp format_result({:compiled, modules}) do
    names =
      modules
      |> Enum.map(fn
        {mod, _beam} -> inspect(mod)
        mod when is_atom(mod) -> inspect(mod)
      end)
      |> Enum.join(", ")

    "compiled and loaded: #{names}\n(use write_file + apply_patch to persist)"
  end

  defp format_result(other) do
    inspect(other, limit: 5000, pretty: true)
  end

  defp build_imports(""), do: ""
  defp build_imports(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&"import #{&1}")
    |> Enum.join("; ")
    |> then(&"; #{&1}")
  end
end
