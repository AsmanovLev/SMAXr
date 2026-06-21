defmodule Smaxr.LLM.Message do
  @moduledoc """
  A single chat message in the conversation history.

  These are the same shape as OpenAI API messages.
  """

  @type t :: %__MODULE__{
          role: :system | :user | :assistant | :tool,
          content: String.t() | nil,
          name: String.t() | nil,
          tool_calls: [map()] | nil,
          tool_call_id: String.t() | nil,
          thinking: String.t() | nil,
          signature: String.t() | nil,
          tool_results: [{String.t(), String.t(), String.t()}] | nil
        }

  defstruct [
    :role,
    :content,
    :name,
    :tool_calls,
    :tool_call_id,
    :thinking,
    :signature,
    :m_id,
    tool_results: nil
  ]

  @spec system(String.t()) :: t()
  def system(text), do: %__MODULE__{role: :system, content: text}

  @spec user(String.t()) :: t()
  def user(text), do: %__MODULE__{role: :user, content: text}

  @spec assistant(String.t(), [map()] | nil) :: t()
  def assistant(text, tool_calls \\ nil),
    do: %__MODULE__{role: :assistant, content: text, tool_calls: tool_calls}

  @spec assistant_with_thinking(String.t(), [map()], String.t(), String.t()) :: t()
  def assistant_with_thinking(text, tool_calls, thinking, signature) do
    %__MODULE__{
      role: :assistant,
      content: text,
      tool_calls: tool_calls,
      thinking: thinking,
      signature: signature
    }
  end

  @spec tool(String.t(), String.t(), String.t()) :: t()
  def tool(content, tool_call_id, name),
    do: %__MODULE__{role: :tool, content: content, tool_call_id: tool_call_id, name: name}

  @spec tool_results([{String.t(), String.t(), String.t()}]) :: t()
  def tool_results(results) when is_list(results) do
    %__MODULE__{role: :tool, tool_results: results, content: ""}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{role: :tool, tool_results: [_, _ | _] = results}) do
    blocks =
      Enum.map(results, fn {content, id, _name} ->
        %{type: "tool_result", tool_use_id: id, content: content || ""}
      end)
    %{"role" => "user", "content" => blocks}
  end
  def to_map(%__MODULE__{role: r, content: c, name: n, tool_calls: tc, tool_call_id: tci}) do
    %{"role" => Atom.to_string(r), "content" => c || ""}
    |> then(fn m -> if n, do: Map.put(m, "name", n), else: m end)
    |> then(fn m -> if tc, do: Map.put(m, "tool_calls", tc), else: m end)
    |> then(fn m -> if tci, do: Map.put(m, "tool_call_id", tci), else: m end)
  end
end
