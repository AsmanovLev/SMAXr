defmodule Smaxr.DCP do
  @moduledoc """
  Dynamic Context Pruning.

  Keeps conversation context within a token budget by:

    * Compressing the **oldest** turns into a one-shot digest (turn-by-turn
      summary) — never breaks tool_use/tool_result pairs
    * Truncating long tool results in the kept slice (keeps cycle intact)
    * Tombstoning tool results that are part of a 3+ retry loop of the
      same tool (deterministic failure detection)
    * Adding a one-line nudge to the system prompt about compression state

  All strategies are non-destructive: tool cycles stay intact, the model
  still sees what tools it called and the (truncated) result.

  DCP is **off by default** — agents with short conversations don't need
  it, and a wrong-prune bug is worse than a long context. Enable via
  `config :smaxr, :dcp_enabled, true` once you've reviewed the digest
  format below and verified it preserves enough context for your tasks.

  ## Configuration

      config :smaxr, :dcp_enabled, true
      config :smaxr, Smaxr.DCP,
        token_budget: 80_000,           # soft cap in tokens (4 chars ≈ 1 token)
        digest_keep_turns: 10,          # last N turns kept verbatim
        tool_result_max_chars: 1500,    # truncate longer tool results
        retry_threshold: 3              # tombstone after N retries of same tool
  """

  alias Smaxr.LLM.Message

  # ── Defaults ────────────────────────────────────────────────────

  @default_token_budget 80_000
  @default_digest_keep_turns 10
  @default_tool_result_max_chars 1500
  @default_retry_threshold 3

  # Heuristic: 4 chars ≈ 1 token (works for English/Cyrillic mix).
  @chars_per_token 4

  @doc """
  Apply DCP strategies to a message history. Returns
  `{new_history, nudge_text, new_state}`.

  Optional opts:
    - `:dcp_state` — previous DCP state (default: fresh state)
    - `:token_budget`, `:digest_keep_turns`, etc.

  When DCP is disabled (the default), the messages are returned
  unchanged, `nudge_text` is empty, `new_state` is the input state.
  """
  def apply_strategies(messages, opts \\ []) do
    dcp_state = Keyword.get(opts, :dcp_state, default_state())
    opts = Keyword.delete(opts, :dcp_state)

    if dcp_enabled?() do
      do_apply(messages, dcp_state, opts)
    else
      {messages, "", dcp_state}
    end
  end

  def default_state do
    %{tombstoned_ids: MapSet.new(), seen_tool_names: %{}}
  end

  defp do_apply(messages, state, opts) do
    budget = Keyword.get(opts, :token_budget, get_config(:token_budget, @default_token_budget))
    keep_turns = Keyword.get(opts, :digest_keep_turns, get_config(:digest_keep_turns, @default_digest_keep_turns))
    max_chars = Keyword.get(opts, :tool_result_max_chars, get_config(:tool_result_max_chars, @default_tool_result_max_chars))
    retry_n = Keyword.get(opts, :retry_threshold, get_config(:retry_threshold, @default_retry_threshold))

    total = estimate_tokens(messages)
    kept = messages

    kept = truncate_long_tool_results(kept, max_chars)
    {kept, state} = tombstone_retry_loops(kept, state, retry_n)

    {kept, _nudge} =
      if total > budget do
        compress_oldest(kept, keep_turns)
      else
        {kept, nudge_for(total, budget)}
      end

    {kept, nudge_for(estimate_tokens(kept), budget), state}
  end

  # ── Token estimation ────────────────────────────────────────────

  @doc "Estimate token count for a list of messages using 4-chars-per-token."
  def estimate_tokens(messages) do
    messages
    |> Enum.map(&message_chars/1)
    |> Enum.sum()
    |> div(@chars_per_token)
  end

  defp message_chars(%Message{content: c, tool_calls: tcs, tool_results: trs, thinking: th}) do
    base = if is_binary(c), do: byte_size(c), else: 0
    base = base + if(is_binary(th), do: byte_size(th), else: 0)

    tc_chars =
      case tcs do
        nil -> 0
        list -> list |> Enum.map(&byte_size(Jason.encode!(&1))) |> Enum.sum()
      end

    tr_chars =
      case trs do
        nil -> 0
        list -> list |> Enum.map(fn {c, _, _} -> if is_binary(c), do: byte_size(c), else: 0 end) |> Enum.sum()
      end

    base + tc_chars + tr_chars
  end

  # ── Compress oldest turns into a digest ─────────────────────────

  # Group messages into "turns" — a user message and everything until the
  # next user message (or end). A turn is typically:
  #   [user, assistant_with_tool_calls, tool_results, assistant_text]
  # We replace old turns with a compact digest describing them, then keep
  # the last `keep_turns` turns verbatim.
  defp compress_oldest(messages, keep_turns) do
    {drop, keep} = split_turns(messages, keep_turns)

    case drop do
      [] ->
        {messages, ""}

      _ ->
        digest = build_digest(drop)
        combined = [digest | keep]
        {combined, "Conversation history was compressed: #{length(drop)} older messages were summarized."}
    end
  end

  # Split messages into (drop, keep) where keep = last `keep_turns` turns.
  # A "turn" starts at a :user message and runs to the message before the
  # next :user. If messages don't end with :user, the trailing turn is
  # also kept (so we never cut mid-turn).
  defp split_turns(messages, keep_turns) do
    user_indices =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> m.role == :user end)
      |> Enum.map(fn {_, i} -> i end)

    case user_indices do
      [] ->
        # No user messages at all — fall back to recent slicing.
        keep_count = keep_turns * 4
        {drop, keep} = Enum.split(messages, max(length(messages) - keep_count, 0))
        {drop, keep}

      _ ->
        if length(user_indices) <= keep_turns do
          # Few turns — keep everything.
          {[], messages}
        else
          # Keep the last keep_turns user message and everything after it.
          cut_at = Enum.at(user_indices, length(user_indices) - keep_turns)
          Enum.split(messages, cut_at)
        end
    end
  end

  # Build a single system message summarizing the dropped turns.
  # Each turn contributes one line: "turn N: user asked X, assistant Y,
  # tools [a, b]". Tool cycle structure is preserved by noting which
  # tools were called — the model can still see *what* it tried, just
  # not the full outputs (those were truncated above).
  defp build_digest(dropped) do
    turns = group_into_turns(dropped)

    lines =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, idx} -> summarize_turn(idx, turn) end)
      |> Enum.join("\n")

    Message.system("""
    [Conversation summary — older turns compressed by DCP]
    The following is a turn-by-turn digest of the earliest #{length(turns)} conversation turns. Full tool outputs were truncated; tool names and their results are noted below. Use this context as a starting point — re-invoke tools (read_file, terminal) if you need their full output.

    #{lines}
    """)
  end

  # Group messages into turns: each turn starts with a :user message
  # and runs to the message before the next :user. The list may have
  # leading non-:user messages (system, etc) — preserve those in turn 0.
  defp group_into_turns(messages) do
    Enum.chunk_by(messages, fn m -> m.role == :user end)
  end

  defp summarize_turn(idx, turn) do
    user_msg = Enum.find(turn, fn m -> m.role == :user end)
    user_text = if user_msg, do: truncate(user_msg.content, 200), else: "(no user text)"

    asst_texts =
      turn
      |> Enum.filter(fn m -> m.role == :assistant and is_binary(m.content) and m.content != "" end)
      |> Enum.map(& &1.content)
      |> Enum.join(" | ")

    asst_summary =
      case asst_texts do
        "" -> "(tool calls only, no text)"
        s -> truncate(s, 250)
      end

    tool_names =
      turn
      |> Enum.flat_map(fn
        %Message{role: :assistant, tool_calls: tcs} when is_list(tcs) ->
          Enum.map(tcs, &tool_name/1)

        %Message{role: :tool, tool_results: trs} when is_list(trs) ->
          Enum.map(trs, fn {_, _, n} -> n end)

        _ ->
          []
      end)
      |> Enum.uniq()
      |> Enum.join(", ")

    tool_part = if tool_names == "", do: "", else: " [tools: #{tool_names}]"
    "  turn #{idx}: user=\"#{user_text}\" → assistant=\"#{asst_summary}\"#{tool_part}"
  end

  defp tool_name(%{"function" => %{"name" => n}}), do: n
  defp tool_name(_), do: nil

  defp truncate(nil, _), do: ""
  defp truncate(s, n) when is_binary(s) and byte_size(s) > n, do: String.slice(s, 0, n) <> "…"
  defp truncate(s, _) when is_binary(s), do: s
  defp truncate(_, _), do: ""

  # ── Truncate long tool results (keep cycle intact) ────────────

  defp truncate_long_tool_results(messages, max_chars) do
    Enum.map(messages, fn
      %Message{role: :tool, content: c} = m when is_binary(c) and byte_size(c) > max_chars ->
        truncated =
          String.slice(c, 0, max_chars) <>
            "\n…[#{byte_size(c) - max_chars} chars truncated by DCP]"

        %{m | content: truncated}

      %Message{role: :tool, tool_results: trs} = m when is_list(trs) ->
        new_results =
          Enum.map(trs, fn {content, id, name} ->
            if is_binary(content) and byte_size(content) > max_chars do
              {String.slice(content, 0, max_chars) <>
                 "\n…[#{byte_size(content) - max_chars} chars truncated by DCP]", id, name}
            else
              {content, id, name}
            end
          end)

        %{m | tool_results: new_results}

      other ->
        other
    end)
  end

  # ── Tombstone retry loops ───────────────────────────────────────

  # When the same tool fails 3+ times in a row, the model is in a retry
  # loop. Replace each failure's content with a tombstone so the model
  # doesn't keep trying, but the tool_use/tool_result pair stays
  # intact (Anthropic requires it).
  defp tombstone_retry_loops(messages, state, threshold) do
    runs = detect_failure_runs(messages, threshold)
    new_runs = MapSet.difference(runs, state.tombstoned_ids)
    combined = MapSet.union(state.tombstoned_ids, new_runs)
    {apply_tombstones(messages, new_runs, threshold), %{state | tombstoned_ids: combined}}
  end

  defp apply_tombstones(messages, target_ids, threshold) do
    Enum.map(messages, fn
      %Message{role: :tool, content: c} = m when is_binary(c) and c != "" ->
        if MapSet.member?(target_ids, m.tool_call_id) do
          %{m | content: "[tombstoned by DCP — #{threshold} consecutive failures]"}
        else
          m
        end

      %Message{role: :tool, tool_results: trs} = m when is_list(trs) ->
        new_results =
          Enum.map(trs, fn {_c, id, name} = triple ->
            if MapSet.member?(target_ids, id) do
              {"[tombstoned by DCP — #{threshold} consecutive failures]", id, name}
            else
              triple
            end
          end)

        %{m | tool_results: new_results}

      other ->
        other
    end)
  end

  # Walk messages and find tool_call_ids that appear in a run of N+
  # consecutive failure results. A "failure" is a tool result whose
  # content matches the failure heuristic.
  defp detect_failure_runs(messages, threshold) do
    tool_msgs =
      Enum.flat_map(messages, fn
        %Message{role: :tool, content: c, tool_call_id: id} when is_binary(c) and not is_nil(id) ->
          [{id, is_failure?(c)}]

        %Message{role: :tool, tool_results: trs} when is_list(trs) ->
          Enum.map(trs, fn {c, id, _name} -> {id, is_failure?(c || "")} end)

        _ ->
          []
      end)

    tool_msgs
    |> Enum.chunk_by(fn {_id, fail?} -> fail? end)
    |> Enum.flat_map(fn chunk ->
      if Enum.all?(chunk, fn {_id, f} -> f end) and length(chunk) >= threshold do
        # All failures in this run; mark tool_call_ids as tombstoned
        # if the run is at least `threshold` long.
        Enum.map(chunk, fn {id, _} -> id end)
      else
        []
      end
    end)
    |> MapSet.new()
  end

  # Heuristic: short message containing common failure markers.
  # We require length < 500 to avoid false-positives on long error logs
  # that the model might want to see.
  defp is_failure?(text) when is_binary(text) do
    cond do
      String.length(text) >= 500 -> false
      String.contains?(String.downcase(text), "error:") -> true
      String.contains?(String.downcase(text), "failed:") -> true
      String.contains?(String.downcase(text), "exception:") -> true
      String.contains?(String.downcase(text), "timeout") -> true
      String.contains?(String.downcase(text), "enoent") -> true
      String.contains?(String.downcase(text), "eacces") -> true
      true -> false
    end
  end

  defp is_failure?(_), do: false

  # ── Nudge ───────────────────────────────────────────────────────

  # No anti-patterns here. The system prompt already tells the model to
  # use tools and to not repeat. The nudge is just a state marker so
  # the model knows context was compressed.
  defp nudge_for(tokens, budget) do
    pct = Float.round(tokens / budget * 100, 1)

    cond do
      pct >= 90 ->
        "Context: #{tokens}/#{budget} tokens (#{pct}%) — older turns compressed. Use tools to re-fetch if needed."

      pct >= 50 ->
        "Context: #{tokens}/#{budget} tokens (#{pct}%)."

      true ->
        ""
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp dcp_enabled? do
    Application.get_env(:smaxr, :dcp_enabled, false)
  end

  defp get_config(key, default) do
    Application.get_env(:smaxr, Smaxr.DCP, []) |> Keyword.get(key, default)
  end
end
