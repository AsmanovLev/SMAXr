defmodule Smaxr.Tools.Shell do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "terminal"

  @impl true
  def description, do: "Execute a shell command and return its output."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        command: %{type: :string, description: "Shell command to execute (PowerShell or cmd)"},
        cwd: %{type: :string, description: "Working directory (default: project root)"}
      },
      required: ["command"]
    }
  end

  def call(args) when is_map(args) and not is_map_key(args, "command") do
    {:error, "missing 'command' argument"}
  end

  @impl true
  def call(%{"command" => cmd} = args) do
    _cwd = Map.get(args, "cwd")
    cmd = sanitize(cmd)

    case Smaxr.Util.safe_cmd("powershell", ["-Command", cmd]) do
      {:error, reason} -> {:error, reason}
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:ok, "exit #{code}:\n#{String.trim(output)}"}
    end
  end

  # Safety net for bash-style commands the LLM occasionally generates.
  # PowerShell's parser breaks on a backtick that's not part of a line
  # continuation or escape. Replace bare backtick command substitution
  # `cmd` with the PowerShell equivalent $(cmd). We do this in a single
  # pass; the LLM is also told to avoid backticks via system prompt.
  defp sanitize(cmd) do
    cmd
    |> String.replace(~r/`([^`]+)`/, "$(\\1)")
  end
end
