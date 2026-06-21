defmodule Smaxr.Tools.Compress do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "compress"

  @impl true
  def description, do: "Compress tool: custom tool, usage depends on context."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        text: %{type: :string, description: "Text to compress"}
      },
      required: ["text"]
    }
  end

  @impl true
  def call(%{"text" => text}) do
    {:ok, "text received (#{byte_size(text)} bytes)"}
  end

  def call(_), do: {:error, "missing 'text' argument"}
end
