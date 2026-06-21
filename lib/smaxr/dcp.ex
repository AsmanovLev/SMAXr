defmodule Smaxr.DCP do
  @moduledoc """
  Dynamic Context Pruning.

  Keeps conversation context within token limits by:
    * Compressing old turns into short summaries
    * Deduplicating tool call cycles
    * Purging error messages
    * Providing nudges to the LLM about context state

  DCP state is per-user, stored in the Agent's state for now.
  """

  alias Smaxr.LLM.Message

  @compress_threshold 20
  @dedup_window 3

  @doc """
  Apply DCP strategies to a message history. Returns {new_history, nudge_text}.

  DCP is off by default — agent keeps full context in memory until the
  user calls /clear. Enable via `config :smaxr, :dcp_enabled, true` if
  you want the old prune behaviour.
  """
  def apply_strategies(messages, opts \\ []) do
    if dcp_enabled?() do
      threshold = Keyword.get(opts, :compress_threshold, @compress_threshold)

      messages =
        messages
        |> maybe_compress(threshold)
        |> dedup_tool_calls()
        |> purge_errors()

      {messages, dcp_nudge(messages)}
    else
      {messages, ""}
    end
  end

  defp dcp_enabled? do
    Application.get_env(:smaxr, :dcp_enabled, false)
  end

  @doc "Check if compression should run based on message count."
  def should_compress?(messages, threshold \\ @compress_threshold) do
    length(messages) > threshold
  end

  # ── Compress ────────────────────────────────────────────────────

  defp maybe_compress(messages, threshold) do
    if length(messages) > threshold do
      {compressable, keep} = split_at_newest(messages, threshold)
      compressed = compress_range(compressable)
      [compressed | keep]
    else
      messages
    end
  end

  # When the conversation grows past threshold, drop the oldest messages
  # by replacing them with a single summary. Naive split would cut mid
  # tool-cycle: e.g. drop everything before the last N messages, but the
  # kept slice might start with `:tool` (orphan tool_results with no
  # preceding tool_use) and the dropped slice might end with `:assistant`
  # (orphan tool_uses with no following tool_result). Anthropic rejects
  # both as 400 errors.
  #
  # Fix: advance the split point forward until the kept slice starts with
  # a `:user` message. If no such point exists, fall back to keeping
  # everything (no compression this turn).
  defp split_at_newest(messages, count) do
    total = length(messages)
    if count >= total do
      {[], messages}
    else
      base_split = total - count

      safe_split =
        base_split
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find(fn idx -> idx >= total or Enum.at(messages, idx).role == :user end)

      case safe_split do
        nil -> {messages, []}
        idx -> Enum.split(messages, idx)
      end
    end
  end

  defp compress_range(messages) do
    roles =
      messages
      |> Enum.group_by(& &1.role)
      |> Enum.map(fn {role, msgs} ->
        "#{role}: #{length(msgs)} messages"
      end)
      |> Enum.join(", ")

    Message.system("[compressed context — #{roles}]")
  end

  # ── Dedup ───────────────────────────────────────────────────────

  defp dedup_tool_calls(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.flat_map(fn
      # Collapse consecutive tool call cycles to keep only last N
      [first_assistant | _] = chunk when first_assistant.role == :assistant ->
        if chunk |> Enum.any?(fn m -> m.tool_calls != nil end) do
          Enum.take(chunk, @dedup_window)
        else
          chunk
        end

      other ->
        other
    end)
  end

  # ── Purge errors ────────────────────────────────────────────────

  defp purge_errors(messages) do
    messages
    |> Enum.filter(fn msg ->
      msg.role != :tool or not is_error_message?(msg.content)
    end)
    |> Enum.map(fn
      msg when msg.role == :tool and msg.content != nil ->
        # Truncate long tool outputs
        if byte_size(msg.content) > 1000,
          do: %{msg | content: String.slice(msg.content, 0, 1000) <> "..."},
          else: msg

      other ->
        other
    end)
  end

  defp is_error_message?(text) when is_binary(text) do
    String.contains?(text, ["error:", "failed:", "timeout"]) and
      String.length(text) < 200
  end

  defp is_error_message?(_), do: false

  # ── Nudge ───────────────────────────────────────────────────────

  defp dcp_nudge(messages) do
    count = length(messages)

    cond do
      count > 50 ->
        "Note: conversation history is long (#{count} messages). Use available tools to discover what you need; do not repeat what is already done."

      count > 30 ->
        "Note: #{count} messages in context. Consider using available tools rather than relying on memory of earlier turns."

      true ->
        ""
    end
  end
end
