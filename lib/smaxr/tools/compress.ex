defmodule Smaxr.Tools.Compress do
  @moduledoc """
  Compress tool — model-driven context compression, inspired by
  [opencode-dcp](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning).

  The model decides *when* and *what* to compress, then writes the
  summary itself. This tool applies the replacement: the agent
  detects the result, splices the range out of `state.messages`, and
  inserts a single system message with the LLM-produced summary.

  Input shape (matches opencode-dcp's `compress-range` tool):

      %{
        "topic"   => "Short label (3-5 words)",
        "content" => [
          %{
            "start_id" => "m3",       # m-prefixed message id
            "end_id"   => "m12",      # inclusive
            "summary"  => "Complete technical summary..."
          },
          ...
        ]
      }

  Bounds: start_id <= end_id, both must exist in the current message
  history. The replacement is applied after the run_llm_loop call
  finishes for this turn (i.e. the model sees the new compressed
  context on its *next* call).
  """
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "compress"

  @impl true
  def description, do:
    "Replace a range of older conversation messages with your own technical " <>
      "summary. Use this when a section of the conversation is closed and you " <>
      "no longer need it verbatim. Each message is referenced by its mN id (e.g. " <>
      "m3..m12). The summary you write becomes the authoritative record for " <>
      "that range — be exhaustive: file paths, function signatures, decisions, " <>
      "constraints, key findings. Strip noise (failed attempts, verbose tool " <>
      "output). Lean but complete."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        topic: %{
          type: :string,
          description: "Short label (3-5 words) for this compression — e.g. 'Auth System Exploration'"
        },
        content: %{
          type: :array,
          description: "One or more ranges to compress",
          items: %{
            type: :object,
            properties: %{
              start_id: %{
                type: :string,
                description: "Message id at the start of the range, e.g. 'm3'"
              },
              end_id: %{
                type: :string,
                description: "Message id at the end of the range (inclusive), e.g. 'm12'"
              },
              summary: %{
                type: :string,
                description: "Complete technical summary that replaces all content in the range"
              }
            },
            required: ["start_id", "end_id", "summary"]
          }
        }
      },
      required: ["topic", "content"]
    }
  end

  @impl true
  def call(%{"topic" => topic, "content" => content} = _args)
      when is_binary(topic) and is_list(content) and content != [] do
    with {:ok, ranges} <- parse_ranges(content) do
      Process.put(:smaxr_compress, {topic, ranges})
      {:ok, "compressed #{length(ranges)} range(s) under '#{topic}'"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def call(%{"topic" => _}) do
    {:error, "compress: 'content' must be a non-empty list of ranges"}
  end

  def call(_), do: {:error, "compress: missing 'topic' or 'content'"}

  # Parse [{"start_id" => "m3", "end_id" => "m7", "summary" => "..."}, ...]
  # to [{3, 7, "..."}, ...] and validate.
  defp parse_ranges(content) do
    Enum.reduce_while(content, {:ok, []}, fn range, {:ok, acc} ->
      with {:ok, start_idx} <- parse_id(Map.get(range, "start_id"), "start_id"),
           {:ok, end_idx} <- parse_id(Map.get(range, "end_id"), "end_id"),
           summary when is_binary(summary) <- Map.get(range, "summary"),
           summary when byte_size(summary) > 0 <- summary,
           true <- start_idx <= end_idx do
        {:cont, {:ok, [{start_idx, end_idx, summary} | acc]}}
      else
        {:error, _} = e -> {:halt, e}
        false -> {:halt, {:error, "compress: start_id must be <= end_id"}}
        nil -> {:halt, {:error, "compress: missing field in range"}}
        "" -> {:halt, {:error, "compress: summary cannot be empty"}}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, Enum.reverse(ranges)}
      error -> error
    end
  end

  # "m3" -> 3, "12" -> 12
  defp parse_id(<<"m", rest::binary>>, label) do
    case Integer.parse(rest) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "compress: invalid #{label} (expected 'mN' with N>0)"}
    end
  end

  defp parse_id(_, label) do
    {:error, "compress: invalid #{label} (expected 'mN' format)"}
  end
end
