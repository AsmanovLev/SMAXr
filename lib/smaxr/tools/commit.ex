defmodule Smaxr.Tools.Commit do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "commit"

  @impl true
  def description, do: "Commit all local changes to git."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        message: %{type: :string, description: "Commit message"}
      },
      required: ["message"]
    }
  end

  @impl true
  def call(%{"message" => message}) do
    project_root = File.cwd!()

    with {_, 0} <- Smaxr.Util.safe_cmd("git", ["add", "-A"], cd: project_root),
         {_, 0} <- Smaxr.Util.safe_cmd("git", ["commit", "-m", message], cd: project_root) do
      {sha, _} = Smaxr.Util.safe_cmd("git", ["rev-parse", "HEAD"], cd: project_root)
      {:ok, "committed: #{String.trim(sha)}"}
    else
      {:error, reason} -> {:error, "commit: #{reason}"}
      {_, code} -> {:error, "commit: git exit #{code}"}
    end
  end

  def call(_), do: {:error, "missing 'message' argument"}
end
