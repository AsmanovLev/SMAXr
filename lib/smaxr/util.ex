defmodule Smaxr.Util do
  @moduledoc "Shared helpers."

  @doc """
  Run a system command safely. Returns `{output, exit_code}` on success,
  or `{:error, message}` if the command cannot be executed.
  """
  def safe_cmd(prog, args, opts \\ []) do
    try do
      case System.cmd(prog, args, Keyword.merge([stderr_to_stdout: true], opts)) do
        {out, code} -> {out, code}
      end
    rescue
      e in ErlangError -> {:error, "#{prog} not available: #{inspect(e.reason)}"}
    end
  end

  @doc """
  Resolve a path and verify it stays within the workdir.
  If workdir is nil or empty, accepts the path as-is (no guard).
  """
  def guard_path(path, workdir) when is_binary(path) and is_binary(workdir) and workdir != "" do
    resolved = Path.expand(path, workdir)
    base = Path.expand(workdir)

    if String.starts_with?(resolved, base) do
      {:ok, resolved}
    else
      {:error, "path escapes workdir: #{path} -> #{resolved} (workdir: #{base})"}
    end
  end

  def guard_path(path, _workdir), do: {:ok, path}
end
