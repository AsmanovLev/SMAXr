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
end
