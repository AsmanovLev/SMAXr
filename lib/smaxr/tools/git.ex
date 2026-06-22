defmodule Smaxr.Tools.Git do
  @behaviour Smaxr.Tool
  alias Smaxr.Util

  @impl true
  def name, do: "git"

  @impl true
  def description, do: "Git operations: commit, push, log, diff, status, sha. Workdir-aware."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          enum: ["commit", "push", "log", "diff", "status", "sha"],
          description: "Git action to perform"
        },
        message: %{
          type: :string,
          description: "Commit message (required for action=commit)"
        },
        n: %{
          type: :integer,
          description: "Number of log entries (default: 10, for action=log)"
        },
        path: %{
          type: :string,
          description: "File path for diff (for action=diff)"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def call(%{"action" => action} = args) do
    workdir = args["_workdir"] || File.cwd!()

    case action do
      "sha" -> git_sha(workdir)
      "log" -> git_log(workdir, Map.get(args, "n", 10))
      "diff" -> git_diff(workdir, Map.get(args, "path", ""))
      "status" -> git_status(workdir)
      "commit" -> git_commit(workdir, args["message"])
      "push" -> git_push(workdir)
    end
  end

  def call(_), do: {:error, "git: missing 'action' argument"}

  defp git_sha(workdir) do
    case Util.safe_cmd("git", ["rev-parse", "--short", "HEAD"], cd: workdir) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {_, _} -> {:error, "git: not a git repository or git not available"}
    end
  end

  defp git_log(workdir, n) when n > 0 do
    case Util.safe_cmd("git", ["log", "--oneline", "-n", Integer.to_string(n)], cd: workdir) do
      {out, 0} -> {:ok, String.trim(out)}
      {_, _} -> {:error, "git: log failed"}
    end
  end

  defp git_diff(workdir, "") do
    case Util.safe_cmd("git", ["diff"], cd: workdir) do
      {out, 0} -> if out == "", do: {:ok, "(no diff)"}, else: {:ok, out}
      {_, _} -> {:error, "git: diff failed"}
    end
  end

  defp git_diff(workdir, path) do
    case Util.safe_cmd("git", ["diff", "--", path], cd: workdir) do
      {out, 0} -> if out == "", do: {:ok, "(no diff)"}, else: {:ok, out}
      {_, _} -> {:error, "git: diff failed for #{path}"}
    end
  end

  defp git_status(workdir) do
    case Util.safe_cmd("git", ["status", "--porcelain"], cd: workdir) do
      {out, 0} ->
        if String.trim(out) == "" do
          {:ok, "clean"}
        else
          {:ok, String.trim(out)}
        end

      {_, _} ->
        {:error, "git: status failed"}
    end
  end

  defp git_commit(_workdir, nil), do: {:error, "git commit: 'message' argument is required"}
  defp git_commit(_workdir, ""), do: {:error, "git commit: 'message' argument is required"}

  defp git_commit(workdir, message) do
    with {_, 0} <- Util.safe_cmd("git", ["add", "-A"], cd: workdir),
         {sha, 0} <- Util.safe_cmd("git", ["commit", "-m", message], cd: workdir) do
      {:ok, "committed #{String.trim(sha)}"}
    else
      {:error, reason} -> {:error, "git commit: #{reason}"}
      {_, code} -> {:error, "git commit: exit #{code}"}
    end
  end

  defp git_push(workdir) do
    with {_, 0} <- Util.safe_cmd("git", ["push"], cd: workdir),
         {out, 0} <- Util.safe_cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workdir) do
      {:ok, "pushed #{String.trim(out)}"}
    else
      {:error, reason} -> {:error, "git push: #{reason}"}
      {_, code} -> {:error, "git push: exit #{code}"}
    end
  end
end
