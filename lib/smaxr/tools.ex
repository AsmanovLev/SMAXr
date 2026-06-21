defmodule Smaxr.Tools do
  @moduledoc """
  Registry for all tools. Each tool implements `Smaxr.Tool` behaviour.
  """

  @builtin_tools [
    Smaxr.Tools.Shell,
    Smaxr.Tools.ReadFile,
    Smaxr.Tools.WriteFile,
    Smaxr.Tools.EditFile,
    Smaxr.Tools.ListDir,
    Smaxr.Tools.DeleteFile,
    Smaxr.Tools.FindFiles,
    Smaxr.Tools.FileInfo,
    Smaxr.Tools.MoveFile,
    Smaxr.Tools.Diff,
    Smaxr.Tools.Grep,
    Smaxr.Tools.WebSearch,
    Smaxr.Tools.Vision,
    Smaxr.Tools.SendFile,
    Smaxr.Tools.Eval,
    Smaxr.Tools.ApplyPatch,
    Smaxr.Tools.Commit,
    Smaxr.Tools.Compress,
    Smaxr.Tools.MCPControl,
    Smaxr.Tools.MCPCall
  ]

  @doc "List all tool specs in OpenAI function-calling format."
  def specs do
    for mod <- available(),
        do: %{
          type: "function",
          function: %{
            name: mod.name(),
            description: mod.description(),
            parameters: mod.parameters()
          }
        }
  end

  @doc "Call a tool by name with the given args."
  def call(name, args) when is_binary(name) do
    mod = lookup(name)

    case mod do
      nil -> {:error, "unknown tool: #{name}"}
      _ -> mod.call(args)
    end
  end

  @doc "List all available tool modules."
  def available, do: @builtin_tools

  defp lookup(name) do
    Enum.find(available(), &(&1.name() == name))
  end
end
