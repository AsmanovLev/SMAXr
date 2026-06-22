defmodule Smaxr.Agent do
  use GenServer
  require Logger

  @max_tools_per_turn 3

  alias Konsolidator.Content
  alias Smaxr.LLM.Message

  defstruct user_id: nil,
            messages: [],
            message_count: 0,
            last_ref: nil,
            model: nil,
            provider: nil,
            max_steps: 200,
            busy: false,
            cancel: false,
            pending: [],
            queue_mode: :deferred

  def child_spec(arg) do
    %{
      id: {__MODULE__, arg},
      start: {__MODULE__, :start_link, [arg]},
      type: :worker,
      restart: :transient
    }
  end

  def whereis(user_id) do
    case Registry.lookup(Smaxr.Registry, {:agent, user_id}) do
      [{_, pid}] -> pid
      _ -> nil
    end
  end

  def start_link(user_id) do
    GenServer.start_link(__MODULE__, user_id)
  end

  def handle_incoming(user_id, source, payload) do
    case whereis(user_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:incoming, source, payload})
    end
  end

  @impl true
  def init(user_id) do
    Registry.register(Smaxr.Registry, {:agent, user_id}, self())
    state = %__MODULE__{user_id: user_id, model: default_model(), provider: Smaxr.Providers.current()}
    {:ok, state}
  end

  defp log_dir do
    case Application.get_env(:smaxr, :data_dir, "priv/smaxr") do
      dir when is_binary(dir) -> Path.join(dir, "logs")
      _ -> "priv/smaxr/logs"
    end
  end

  defp log_path(user_id) do
    Path.join(log_dir(), "chat_#{user_id}.log")
  end

  defp chat_log(user_id, kind, data) do
    dir = log_dir()
    File.mkdir_p!(dir)
    path = log_path(user_id)

    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "#{ts} [#{kind}] #{data}\n"

    File.write!(path, line, [:append])
  rescue
    _ -> :ok
  end

  @impl true
  def handle_cast({:incoming, _source, %{text: text} = payload}, state) when is_binary(text) do
    state = %{state | message_count: state.message_count + 1, last_ref: payload.ref}
    Logger.info("[agent #{state.user_id}] incoming text: #{String.slice(text, 0, 100)}")
    chat_log(state.user_id, "incoming", text)

    case Smaxr.Commands.parse(text) do
      {:command, cmd, args} ->
        send_input_marker(state, "/#{cmd} #{args}" |> String.trim())
        {:handled, reply, new_state} = Smaxr.Commands.execute(cmd, args, :telegram, state)
        Logger.info("[agent #{state.user_id}] command /#{cmd} handled")

        chat_log(
          new_state.user_id,
          "command",
          "/#{cmd} #{args} -> #{String.slice(reply, 0, 200)}"
        )

        reply_to_user(new_state, reply, :text)
        {:noreply, new_state}

      nil ->
        if state.busy do
          case state.queue_mode do
            :instant ->
              # Write to persistent_term — the running LLM loop picks it up
              existing = :persistent_term.get({__MODULE__, :inject, state.user_id}, [])
              :persistent_term.put({__MODULE__, :inject, state.user_id}, existing ++ [text])
              Logger.info("[agent #{state.user_id}] instant-injected: #{String.slice(text, 0, 80)}")
              chat_log(state.user_id, "instant_inject", text)
              reply_to_user(state, "⚡ injected (instant)", :text)
              {:noreply, state}

            _ ->
              new_state = enqueue_pending(state, text)
              n = length(new_state.pending)
              Logger.info("[agent #{state.user_id}] queued (now #{n})")
              chat_log(state.user_id, "queued", "n=#{n} text=#{String.slice(text, 0, 80)}")
              reply_to_user(new_state, "⏸ queued (#{n} pending) — will be sent on next turn", :text)
              {:noreply, new_state}
          end
        else
          # Inject any messages that were queued before this one, then
          # start a new turn with the combined context.
          state = drain_pending_into_context(state)
          send_input_marker(state, text)
          send_typing(state)
          state = spawn_turn(state, text)
          {:noreply, state}
        end
    end
  end

  def handle_cast({:incoming, _source, %{button_data: data}}, state) when is_binary(data) do
    Logger.info("[agent #{state.user_id}] button: #{data}")

    case Smaxr.Commands.parse("/" <> data) do
      {:command, cmd, args} ->
        send_input_marker(state, "/" <> data)
        {:handled, reply, new_state} = Smaxr.Commands.execute(cmd, args, :telegram, state)
        reply_to_user(new_state, reply, :text)
        {:noreply, new_state}

      nil ->
        if state.busy do
          case state.queue_mode do
            :instant ->
              existing = :persistent_term.get({__MODULE__, :inject, state.user_id}, [])
              :persistent_term.put({__MODULE__, :inject, state.user_id}, existing ++ ["[button] #{data}"])
              reply_to_user(state, "⚡ injected (instant)", :text)
              {:noreply, state}

            _ ->
              new_state = enqueue_pending(state, "[button] #{data}")
              n = length(new_state.pending)
              reply_to_user(new_state, "⏸ queued (#{n} pending)", :text)
              {:noreply, new_state}
          end
        else
          state = drain_pending_into_context(state)
          send_input_marker(state, "[button] " <> data)
          send_typing(state)
          state = spawn_turn(state, data, :button)
          {:noreply, state}
        end
    end
  end

  def handle_cast(_, state), do: {:noreply, state}

  # Result from a Task: the LLM work is done (or cancelled). Update
  # state, decide whether to drain pending, and reply.
  @impl true
  def handle_info({:turn_done, task_state, steps, sent}, state) do
    # Pull the updated messages/count from the task's working state.
    # Always mark agent idle when a turn completes (any branch).
    state = %{
      state
      | messages: task_state.messages,
        message_count: task_state.message_count,
        busy: false,
        cancel: false
    }

    was_cancelled = cancel_flag?(state.user_id)
    clear_cancel_flag(state.user_id)

    cond do
      was_cancelled ->
        Logger.info("[agent #{state.user_id}] turn cancelled after #{steps} steps")
        chat_log(state.user_id, "cancelled", "steps=#{steps}")
        send_end_marker(state, steps)
        reply_to_user(state, "🛑 stopped.", :text)
        {:noreply, cleanup_instant_inject(state)}

      true ->
        state = cleanup_instant_inject(state)
        {state, steps} = enforce_response(state, steps, 0, sent)
        send_end_marker(state, steps)
        # If a message arrived during the turn, it was queued. Now
        # inject it into context as a follow-up user message and run
        # another turn. The follow-up turn runs in the same handle_info
        # call (synchronous), so /stop during a drain just sets the
        # flag for the next check.
        case state.pending do
          [] ->
            {:noreply, state}

          pending ->
            Logger.info("[agent #{state.user_id}] auto-injecting #{length(pending)} queued")
            chat_log(state.user_id, "injected", "n=#{length(pending)}")
            joined = format_pending(pending)
            state = %{state | pending: []}
            state = push(state, Message.user(joined))

            try do
              {state, steps, sent} = run_llm_loop(state, 0, 0)
              {state, steps} = enforce_response(state, steps, 0, sent)
              send_end_marker(state, steps)
            rescue
              e ->
                stack = Exception.format_stacktrace(__STACKTRACE__)
                Logger.error("[agent #{state.user_id}] Auto-inject LLM crashed: #{inspect(e)}\n#{stack}")
                reply_to_user(state, "💥 <i>auto-inject failed — try again</i>", :html)
                cleanup_instant_inject(state)
            catch
              kind, reason ->
                Logger.error("[agent #{state.user_id}] Auto-inject exited: #{inspect(kind)} #{inspect(reason)}")
                reply_to_user(state, "💥 <i>auto-inject failed — try again</i>", :html)
                cleanup_instant_inject(state)
            end

            {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Pending queue + turn spawning + cancel flag ──────────────────

  defp enqueue_pending(state, text) do
    %{state | pending: state.pending ++ [{text, System.os_time(:millisecond)}]}
  end

  # Spawn a Task to do the LLM work. The agent's main process is
  # immediately free to handle /stop, /queue, and incoming messages
  # (which are queued in pending).
  defp spawn_turn(state, text, kind \\ :text) do
    :persistent_term.put({__MODULE__, :cancel, state.user_id}, false)
    parent = self()
    initial_state = state

    Task.Supervisor.start_child(Smaxr.EvalSupervisor, fn ->
      try do
        s =
          case kind do
            :text -> push(initial_state, Message.user(text))
            :button -> push_button(initial_state, text)
          end

        {s, steps, sent} = run_llm_loop(s, 0, 0)
        send(parent, {:turn_done, s, steps, sent})
      rescue
        e ->
          stack = Exception.format_stacktrace(__STACKTRACE__)
          Logger.error("[agent #{initial_state.user_id}] Task crashed: #{inspect(e)}\n#{stack}")
          cleanup_instant_inject(initial_state)
          reply_to_user(initial_state, "💥 <i>internal error — agent recovered</i>", :html)
          send(parent, {:turn_done, initial_state, 0, false})
      catch
        kind, reason ->
          Logger.error("[agent #{initial_state.user_id}] Task exited: #{inspect(kind)} #{inspect(reason)}")
          cleanup_instant_inject(initial_state)
          reply_to_user(initial_state, "💥 <i>internal error — agent recovered</i>", :html)
          send(parent, {:turn_done, initial_state, 0, false})
      end
    end)

    %{state | busy: true}
  end

  # Drain queued messages into the context as a single user message.
  # Used when a new turn starts and there are messages waiting.
  defp drain_pending_into_context(state) do
    case state.pending do
      [] ->
        state

      pending ->
        joined = format_pending(pending)
        state = %{state | pending: []}
        push(state, Message.user(joined))
    end
  end

  defp format_pending(pending) do
    body =
      pending
      |> Enum.map(fn {text, ts} ->
        "[#{DateTime.from_unix!(div(ts, 1000)) |> DateTime.to_iso8601()}] #{text}"
      end)
      |> Enum.join("\n\n")

    "These messages arrived while I was busy. Read them as additional " <>
      "context from the user, in order:\n\n#{body}"
  end

  defp cancel_flag?(user_id) do
    :persistent_term.get({__MODULE__, :cancel, user_id}, false)
  end

  defp set_cancel_flag(user_id, value) do
    :persistent_term.put({__MODULE__, :cancel, user_id}, value)
  end

  defp clear_cancel_flag(user_id) do
    :persistent_term.put({__MODULE__, :cancel, user_id}, false)
  end

  # Drain messages that were written into persistent_term by instant-inject.
  # Called at the top of each run_llm_loop iteration. After the loop ends
  # any remaining are cleaned up so they don't carry across turns.
  defp drain_instant_inject(state) do
    case :persistent_term.get({__MODULE__, :inject, state.user_id}, []) do
      [] ->
        state

      texts ->
        :persistent_term.erase({__MODULE__, :inject, state.user_id})
        joined = Enum.join(texts, "\n")
        Logger.info("[agent #{state.user_id}] draining #{length(texts)} instant-injected messages")
        chat_log(state.user_id, "drain_instant", "n=#{length(texts)}")
        push(state, Message.user(joined))
    end
  end

  # Clean up any leftover instant-inject state after a turn completes
  defp cleanup_instant_inject(state) do
    :persistent_term.erase({__MODULE__, :inject, state.user_id})
    state
  end

  # ── /stop, /abort, /queue ─────────────────────────────────────────

  # /stop and /abort set the cancel flag. run_llm_loop checks it
  # between steps, so the LLM work exits at the next step boundary.
  # /queue shows the current pending list.

  def do_stop(state) do
    if state.busy do
      set_cancel_flag(state.user_id, true)
      {:ok, "🛑 stopping at next step boundary…", state}
    else
      {:ok, "🛑 stopped (was idle).", state}
    end
  end

  def do_queue(state, args \\ "") do
    case String.trim(args) do
      "instant" ->
        {:handled, "⚡ queue mode set to **instant** — messages will inject mid-turn", %{state | queue_mode: :instant}}

      "deferred" ->
        {:handled, "⏸ queue mode set to **deferred** — messages queue until turn ends", %{state | queue_mode: :deferred}}

      _ ->
        mode_label = if state.queue_mode == :instant, do: "⚡ instant", else: "⏸ deferred"
        pending_info =
          case state.pending do
            [] -> "empty"
            pending ->
              preview =
                pending
                |> Enum.take(5)
                |> Enum.map(fn {text, _ts} -> "• #{String.slice(text, 0, 80)}" end)
                |> Enum.join("\n")
              more = if length(pending) > 5, do: "\n…and #{length(pending) - 5} more", else: ""
              "#{length(pending)} pending:\n#{preview}#{more}"
          end
        {:handled, "📬 queue mode: #{mode_label}\n#{pending_info}\n\n`/queue instant` — inject mid-turn\n`/queue deferred` — queue until turn ends", state}
    end
  end

  # ── LLM + tool loop ──────────────────────────────────────────────

  defp run_llm_loop(state, step, total_steps) do
    cond do
      step >= state.max_steps ->
        Logger.warning("[agent #{state.user_id}] max steps reached (#{state.max_steps})")
        reply_to_user(state, "max steps reached (#{state.max_steps})", :text)
        {state, total_steps, true}

      cancel_flag?(state.user_id) ->
        Logger.info("[agent #{state.user_id}] run_llm_loop: cancel at step #{step}")
        {state, total_steps, false}

      true ->
        # Pick up any instant-injected messages that arrived during the previous step
        state = drain_instant_inject(state)
        typing_pid = start_typing_loop(state)
        Logger.info("[agent #{state.user_id}] LLM call (step #{step})")
        result = call_llm(state, step)
        stop_typing(typing_pid)

        case result do
          {:ok, %Message{tool_calls: nil, content: text}, usage}
          when is_binary(text) and text != "" ->
            state = push(state, Message.assistant(text))

            Logger.info(
              "[agent #{state.user_id}] LLM response: #{String.slice(text, 0, 100)} | tokens: #{usage["total_tokens"]}"
            )

            chat_log(state.user_id, "llm_response", text)
            reply_to_user(state, text, :markdown)
            {state, total_steps + 1, true}

          {:ok, %Message{tool_calls: tool_calls, content: text, thinking: t, signature: s}, usage}
          when tool_calls != nil ->
            Logger.info(
              "[agent #{state.user_id}] LLM tool_calls: #{Enum.map(tool_calls, & &1["function"]["name"]) |> Enum.join(", ")}"
            )

            chat_log(
              state.user_id,
              "llm_tool_calls",
              Enum.map_join(tool_calls, ",", & &1["function"]["name"])
            )

            # Cap BEFORE pushing assistant message — if we drop tool_uses,
            # we must also drop their tool_results, or the next request
            # has unmatched tool_use ids → 400 from Anthropic.
            tool_calls = Enum.take(tool_calls, @max_tools_per_turn)

            state = push(state, Message.assistant_with_thinking(text || "", tool_calls, t, s))
            state = execute_tool_calls(state, tool_calls, step, prompt_tokens(usage))
            run_llm_loop(state, step + 1, total_steps + 1)

          {:ok, %Message{content: ""}, _usage} ->
            Logger.warning("[agent #{state.user_id}] LLM empty response (no text, no tool_calls)")
            chat_log(state.user_id, "llm_empty", "no text and no tool_calls")
            # Push a marker so enforce_response can detect "ended without text"
            state = push(state, Message.assistant(""))
            {state, total_steps, false}

          {:error, reason} ->
            Logger.error("[agent #{state.user_id}] LLM call failed: #{inspect(reason)}")
            chat_log(state.user_id, "llm_error", inspect(reason))
            {state, total_steps, false}
        end
    end
  end

  defp send_end_marker(state, steps) do
    msg =
      case steps do
        0 -> "🏁 <i>end of loop (no LLM calls)</i>"
        n -> "🏁 <i>end of loop (#{n} step#{if n == 1, do: "", else: "s"})</i>"
      end
    reply_to_user(state, msg, :html)
  end

  # Echo user's input back as a small left-arrow marker before processing.
  # Heavily truncated, with char/token count if input was long.
  @max_input_display 200

  defp send_input_marker(state, text) do
    byte_size = byte_size(text)
    truncated = truncate_text(text, @max_input_display)
    est_tokens = div(byte_size, 4)
    size_info =
      cond do
        byte_size <= @max_input_display -> "#{format_num(byte_size)} chars"
        true -> "#{format_num(byte_size)} chars (~#{format_num(est_tokens)} tok) → showing #{@max_input_display}"
      end
    msg = "← <i>#{escape_html(truncated)}</i>\n<pre>#{size_info}</pre>"
    reply_to_user(state, msg, :html)
  end

  defp truncate_text(text, max) when is_binary(text) do
    if byte_size(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # Penalty: if the loop ended without a final text response (LLM only
  # called tools, then came back empty), inject a system message and try
  # once more. Cap retries to avoid infinite loops.
  @max_response_retries 2

  defp enforce_response(state, steps, retries, sent) do
    if sent do
      {state, steps}
    else
      if retries >= @max_response_retries do
        Logger.warning("[agent #{state.user_id}] no response after #{retries} retries — giving up")
        chat_log(state.user_id, "no_response", "gave up after #{retries} retries")
        # Build a local fallback from tool results so the user gets *something*
        # instead of silence. Use last few tool messages.
        fallback = build_fallback(state)
        reply_to_user(state, fallback, :markdown)
        {state, steps}
      else
        Logger.info("[agent #{state.user_id}] no text reply — re-prompting (retry #{retries + 1})")
        chat_log(state.user_id, "reprompt", "retry #{retries + 1}")
        # Drop the previous assistant's thinking block (and its content) so
        # the retry starts with a clean slate — otherwise the model keeps
        # re-generating thinking-only responses.
        state = %{state | messages: Enum.map(state.messages, fn
          %Smaxr.LLM.Message{role: :assistant, content: c} = m ->
            %Smaxr.LLM.Message{m | content: c || "", thinking: nil, signature: nil}
          m -> m
        end)}
        state = push(state, Message.user(
          "⚠️ You cannot leave without responding to the user. " <>
          "If you called tools above, summarize your findings NOW in plain text. " <>
          "If you have nothing to say, say so explicitly. " <>
          "ABSOLUTELY NO THINKING — respond with the final answer in a single text block."
        ))
        {state, steps, sent} = run_llm_loop(state, 0, steps)
        enforce_response(state, steps, retries + 1, sent)
      end
    end
  end

  # Build a fallback summary from the last few tool results when the LLM
  # fails to respond. Picks the most recent tool message and trims it.
  defp build_fallback(state) do
    last_tool_msg =
      state.messages
      |> Enum.reverse()
      |> Enum.find(fn
        %Smaxr.LLM.Message{role: :tool} -> true
        _ -> false
      end)

    case last_tool_msg do
      %Smaxr.LLM.Message{role: :tool, tool_results: results} when is_list(results) ->
        # Pull out the first result text and trim aggressively
        case results do
          [{text, _id, name} | _] when is_binary(text) ->
            preview = String.slice(text, 0, 1200)
            "⚠️ _LLM did not respond — sharing last tool output instead._\n\n" <>
              "<b>#{name}</b>\n<pre>#{escape_html(preview)}</pre>"

          _ ->
            "⚠️ _LLM did not respond, and no tool results available._"
        end

      _ ->
        "⚠️ _LLM did not respond (no tool results to show)._"
    end
  end

  defp call_llm(state, _step) do
    model = state.model || default_model()
    provider_id = state.provider || Smaxr.Providers.current()
    provider_mod = provider_module(provider_id)
    tools_specs = Smaxr.Tools.specs()

    {messages, nudge} = Smaxr.DCP.apply_strategies(state.messages)
    history = build_history(messages, nudge)

    case provider_mod.call(model, history, tools: tools_specs) do
      {:ok, msg, usage} -> {:ok, msg, usage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_module(provider_id) do
    case Enum.find(Smaxr.Providers.list(), fn p -> p.id == provider_id end) do
      %{module: mod} -> mod
      nil -> Smaxr.LLM.OpenAI
    end
  end

  defp build_history(messages, nudge) do
    # system_prompt/0 already returns %Message{}, no need to wrap again.
    msg_list = if(nudge != "", do: messages ++ [Message.system(nudge)], else: messages)
    [system_prompt() | msg_list]
  end

  @doc false
  def execute_tool_calls(state, tool_calls, step, prompt \\ nil) do
    # Cap simultaneous tools to avoid (a) Telegram rate limits, (b) context
    # blow-up when LLM returns 5+ parallel calls, (c) duplicate tool_use_id
    # collisions when same name appears multiple times.
    tool_calls = Enum.take(tool_calls, @max_tools_per_turn)
    skipped = max(length(tool_calls) - @max_tools_per_turn, 0)

    ctx_line = if(prompt, do: "\n\n#{format_context(prompt, state.model)}", else: "")

    annotation =
      build_annotation(tool_calls) <>
        if(skipped > 0, do: "\n<i>… #{skipped} more dropped (cap=#{@max_tools_per_turn})</i>", else: "")

    {acc, ref} = reply_get_ref(state, annotation <> ctx_line, :html)
    send_typing(state)

    # Execute tools with their original index so tool_use_id is unique.
    {results, acc} =
      tool_calls
      |> Enum.with_index()
      |> Enum.reduce({[], acc}, fn {tc, idx}, {results, acc} ->
        name = tc["function"]["name"]
        args_raw = tc["function"]["arguments"]

        args =
          case Jason.decode(args_raw) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end

        Logger.info(
          "[agent #{state.user_id}] tool #{step}/#{length(tool_calls)}[#{idx}]: #{name}(#{inspect(args, limit: 100)})"
        )

        chat_log(state.user_id, "tool_call", "#{name}(#{inspect(args, limit: 100)})")

        result = Smaxr.Tools.call(name, args)

        Logger.info(
          "[agent #{state.user_id}] tool #{name} result: #{inspect(result, limit: 200)}"
        )

        chat_log(state.user_id, "tool_result", "#{name}: #{inspect(result, limit: 500)}")

        result_text =
          case result do
            {:ok, res} -> inspect(res, limit: 2000)
            {:error, err} -> err
          end

        # Use the tc's own id, falling back to a synthetic unique one.
        # Same-name calls (3x read_file) now get different ids because
        # each tc has its own "id" field from the LLM.
        id = tc["id"] || tc[:id] || "tool_#{idx}_#{System.unique_integer([:positive])}"
        {[{result_text, id, name, args, result} | results], acc}
      end)

    # Edit the single annotation with all results stacked
    if ref do
      output =
        Enum.map_join(Enum.reverse(results), "\n\n", fn {_t, _id, name, args, result} ->
          args_text =
            case format_args(args) do
              "" -> ""
              a -> "<pre>#{escape_html(a)}</pre>"
            end

          body =
            case result do
              {:ok, res} when is_binary(res) -> truncate_head(res, 1500) |> escape_html()
              {:ok, res} -> res |> inspect(limit: 3000) |> truncate_head(1500) |> escape_html()
              {:error, err} -> "✗ #{escape_html(err)}"
            end

          out_block = "<pre>#{body}</pre>"
          "<b>#{escape_html(name)}</b>\n#{args_text}#{out_block}"
        end)

      edit_message(acc, ref, "#{annotation}\n\n#{output}#{ctx_line}", :html)
    end

    # Push all tool results as a single user message (Anthropic requires it)
    api_results =
      Enum.map(Enum.reverse(results), fn {text, id, name, _args, _result} -> {text, id, name} end)

    acc = push(acc, Message.tool_results(api_results))

    # Apply any pending compress request from this turn. The compress
    # tool stashes {topic, ranges} in Process dict; we splice those
    # ranges out of the message history now and inject a single
    # system message with the topic and summaries.
    apply_pending_compress(acc)
  end

  # Apply the compress tool's pending replacement. Ranges are 1-indexed
  # positions in `state.messages` (m1, m2, ...). We work from the
  # highest range to the lowest so earlier indices don't shift under us.
  # Overlapping or out-of-bounds ranges are dropped silently — the
  # model will see the LLM-generated summary in the next turn
  # regardless.
  defp apply_pending_compress(state) do
    case Process.get(:smaxr_compress) do
      nil ->
        state

      {topic, ranges} ->
        Process.delete(:smaxr_compress)
        sorted = Enum.sort_by(ranges, fn {s, _e, _} -> -s end)
        new_messages = Enum.reduce(sorted, state.messages, &splice_range/2)
        # Re-assign m_ids so the model can still reference messages
        # by their (now-different) positions in the next turn.
        renumbered =
          new_messages
          |> Enum.with_index(1)
          |> Enum.map(fn {m, idx} -> %{m | m_id: idx} end)

        chat_log(state.user_id, "compress", "topic=#{topic} ranges=#{length(ranges)}")

        compressed_block = compress_block_message(topic, ranges)
        final = renumbered ++ [compressed_block]
        %{state | messages: final}
    end
  end

  defp splice_range({start_idx, end_idx, _summary}, messages) do
    before = Enum.take(messages, start_idx - 1)
    after_ = Enum.drop(messages, end_idx)
    before ++ after_
  end

  defp compress_block_message(topic, ranges) do
    body =
      ranges
      |> Enum.map_join("\n\n", fn {s, e, summary} ->
        "## m#{s}..m#{e}\n\n#{summary}"
      end)

    Message.system("""
    [Compressed conversation section — topic: #{topic}]

    #{body}

    End of compressed section. Use these summaries as context; the raw
    messages in this range have been removed. Re-invoke tools (read_file,
    terminal) if you need full content from earlier turns.
    """)
  end

  defp build_annotation([tc]) do
    name = tc["function"]["name"]

    args =
      case Jason.decode(tc["function"]["arguments"] || "{}") do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    args_display = format_args(args)

    if args_display == "",
      do: "🔧 #{escape_html(name)}",
      else: "🔧 <b>#{escape_html(name)}</b>\n<pre>#{escape_html(args_display)}</pre>"
  end

  defp build_annotation(tool_calls) do
    names = tool_calls |> Enum.map(& &1["function"]["name"]) |> Enum.uniq()

    summary =
      if length(names) <= 5,
        do: Enum.join(names, ", "),
        else: Enum.join(Enum.take(names, 4), ", ") <> " +#{length(names) - 4}"

    "🔧 <b>#{length(tool_calls)} tools</b>\n<i>#{escape_html(summary)}</i>"
  end

  # Format tool args for display: single-arg tools show just the value,
  # multi-arg tools show as JSON.
  defp format_args(args) when map_size(args) == 0, do: ""

  defp format_args(args) when map_size(args) == 1 do
    [{_key, value}] = Map.to_list(args)
    to_string(value)
  end

  defp format_args(args), do: Jason.encode!(args)

  # ── Delivery ─────────────────────────────────────────────────────

  defp send_typing(state) do
    try do
      Konsolidator.Adapters.Telegram.typing(Konsolidator.Adapters.Telegram, state.user_id, :on)
    catch
      _, _ -> :ok
    end
  end

  # Spawn a process that keeps typing for the duration of LLM processing.
  # Returns the pid; caller should kill it when done.
  defp start_typing_loop(state) do
    pid = spawn(fn -> typing_loop(state.user_id) end)
    pid
  end

  defp typing_loop(user_id) do
    send_typing_loop(user_id)
    Process.sleep(4_000)
    typing_loop(user_id)
  end

  defp send_typing_loop(user_id) do
    try do
      Konsolidator.Adapters.Telegram.typing(Konsolidator.Adapters.Telegram, user_id, :on)
    catch
      _, _ -> :ok
    end
  end

  defp stop_typing(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        Process.exit(pid, :kill)
      catch
        _, _ -> :ok
      end
    end
  end

  # Send message and return {new_state, ref}
  defp reply_get_ref(state, text, parse_mode) do
    content = %Content{text: text, parse_mode: parse_mode}
    adapter = Konsolidator.Adapters.Telegram

    case safe_send(adapter, state.user_id, content) do
      {:ok, new_ref} -> {%{state | last_ref: new_ref}, new_ref}
      {:error, _reason} -> {state, nil}
    end
  end

  # Edit an existing message by ref
  defp edit_message(state, ref, text, parse_mode) do
    content = %Content{text: text, parse_mode: parse_mode}

    try do
      Konsolidator.Adapters.Telegram.edit(
        Konsolidator.Adapters.Telegram,
        state.user_id,
        ref,
        content
      )
    catch
      _, _ -> :ok
    end

    state
  end

  defp reply_to_user(state, text, parse_mode) do
    text = strip_dcp_tags(text)

    Logger.info(
      "[agent #{state.user_id}] send (len=#{byte_size(text)}): #{String.slice(text, 0, 80)}"
    )

    content = %Content{text: text, parse_mode: parse_mode}
    adapter = Konsolidator.Adapters.Telegram

    case safe_send(adapter, state.user_id, content) do
      {:ok, new_ref} ->
        %{state | last_ref: new_ref}

      {:error, reason} ->
        Logger.warning("[agent #{state.user_id}] send failed: #{inspect(reason)}")
        state
    end
  end

  # Keep last `max` bytes; if truncated, prepend a marker showing how much was cut.
  defp truncate_head(text, max) when is_binary(text) do
    if byte_size(text) > max do
      cut = byte_size(text) - max
      "…✂️ [#{format_num(cut)} truncated]\n" <> String.slice(text, cut, max)
    else
      text
    end
  end

  defp strip_dcp_tags(text) when is_binary(text) do
    text
    |> String.replace(~r/<dcp-message-id>m\d+<\/dcp-message-id>\n?/, "")
  end

  defp strip_dcp_tags(text), do: text

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp push(state, message) do
    next_id = length(state.messages) + 1
    %{state | messages: state.messages ++ [%{message | m_id: next_id}]}
  end

  defp push_button(state, data) do
    push(state, Message.user("button: #{data}"))
  end

  defp system_prompt do
    extra =
      Application.get_env(:smaxr, Smaxr.LLM.OpenAI, [])
      |> Keyword.get(:system_prompt, "")

    tool_names =
      Smaxr.Tools.available()
      |> Enum.map(&"  - #{&1.name()}: #{&1.description()}")
      |> Enum.join("\n")

    cmd_names =
      Smaxr.Commands.commands_map()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&"  /#{&1}")
      |> Enum.join("\n")

    body =
      """
      You are SMAXr, a Self-Modifying ai Agent written in eliXir.

      ## Rules
      - You MUST end every turn with a text response to the user. Calling tools without a final answer is NOT allowed.
      - Reply to user about what or why you're doing per every step
      - Invoke multiple tools (be aware of tools are going to be executed in parralel)
      - Never end a turn with tool calls only — always follow up with a text reply.
      - Hard cap: max 3 tool calls per turn. If you need more, sequence them across turns.

      ## Context management (DCP)
      You operate in a context-constrained environment. Manage context continuously to avoid buildup. The `compress` tool replaces older, closed conversation content with technical summaries you write.

      When to compress: a section is genuinely closed (research concluded, implementation verified, exploration exhausted) AND the raw content is no longer needed verbatim. Before compressing, ask: "Is this section closed enough to become summary-only right now?"

      When NOT to compress: raw context is still needed for edits or precise references; the target is actively in progress; you may need exact code/errors in the immediate next steps.

      Your summary must be EXHAUSTIVE — file paths, function signatures, decisions, constraints, key findings. Strip noise (failed attempts, verbose tool output) but preserve every fact that maintains context integrity. User intent must be preserved exactly — prefer direct quotes for short user messages.

      `mN` ids in `<dcp-message-id>mNNNN</dcp-message-id>` style are environment-injected. Do not output them.

      ## Available tools
      #{tool_names}

      ## Available commands
      #{cmd_names}

      ### Current terminal shell
      #{detect_shell()}

      ### Shell rules (READ — your commands must follow these)
      - **NEVER use bash backtick substitution** (\\`cmd\\`) — PowerShell parser errors on backticks. Use $() instead: \\`$(Get-Date -Format 'HH:mm')\\` → `$(Get-Date -Format 'HH:mm')`.
      - Use **single or double quotes** around paths with spaces. Don't try to escape spaces with backslashes inside double-quoted PowerShell strings.
      - `Get-ChildItem` does NOT have `-la`. Use `-Force` to show hidden, or just list and read the names you need.
      - Prefer **one-liner pipelines** that work in PowerShell 5+ (no PS7-only syntax like `??` or `??=`).
      - If a command must contain a literal backtick (rare), double it: `` \\`\\` `` — but prefer avoiding backticks entirely.

      ### Workdir
      #{File.cwd!()}
      """ <> if(extra != "", do: "\n## Extra context\n#{extra}", else: "")

    Message.system(body)
  end

  defp detect_shell do
    cond do
      # GitBash has MSYSTEM env
      System.get_env("MSYSTEM") -> "GitBash (#{System.get_env("MSYSTEM")})"
      # WSL has WSL_DISTRO_NAME
      System.get_env("WSL_DISTRO_NAME") -> "WSL (#{System.get_env("WSL_DISTRO_NAME")})"
      # PowerShell sets PSModulePath
      System.get_env("PSModulePath") -> "PowerShell"
      # GitHub Actions / CI
      System.get_env("GITHUB_ACTIONS") == "true" -> "CI"
      # Fallback: assume PowerShell on Windows, sh elsewhere
      match?({:win32, _}, :os.type()) -> "PowerShell (assumed)"
      true -> "sh"
    end
  end

  defp default_model do
    Application.get_env(:smaxr, Smaxr.LLM.OpenAI, [])
    |> Keyword.get(:default_model, "deepseek-v4-flash")
  end

  defp safe_send(adapter, user_id, content) do
    try do
      adapter.send(adapter, user_id, content)
    catch
      :exit, {:noproc, _} -> {:error, :adapter_not_running}
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # ── Context usage ────────────────────────────────────────────────

  defp prompt_tokens(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage["prompt_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0
    cache_write = usage["cache_creation_input_tokens"] || 0
    if input + cache_read + cache_write > 0, do: input + cache_read + cache_write, else: nil
  end

  defp prompt_tokens(_), do: nil

  defp context_window(model) when model in ["deepseek-v4-flash", "deepseek-chat", "deepseek-v3"],
    do: 500_000

  defp context_window(model) when model in ["deepseek-v4-flash-1m", "deepseek-chat-1m"],
    do: 1_000_000

  defp context_window(model)
       when model in [
              "claude-3-5-sonnet-latest",
              "claude-3-5-sonnet-20241022",
              "claude-3-opus-latest",
              "claude-3-haiku-20240307"
            ],
       do: 200_000

  defp context_window(model) when is_binary(model) do
    cond do
      String.contains?(model, "gpt-4o") -> 128_000
      String.contains?(model, "gpt-4-turbo") -> 128_000
      String.contains?(model, "gpt-4") -> 8_192
      String.contains?(model, "gpt-3.5") -> 16_385
      String.contains?(model, "claude") -> 200_000
      true -> 200_000
    end
  end

  defp context_window(_), do: 200_000

  defp format_context(tokens, model) do
    max = context_window(model)
    pct = tokens / max * 100
    bar = make_bar(pct, 15)
    "📊 <i>#{format_num(tokens)} / #{format_num(max)} (#{Float.round(pct, 1)}%)</i>  #{bar}"
  end

  defp make_bar(pct, width) do
    filled = round(pct / 100 * width) |> max(0) |> min(width)
    empty = width - filled
    color = if pct >= 80, do: "🔴", else: if(pct >= 50, do: "🟡", else: "🟢")
    "#{String.duplicate("█", filled)}#{String.duplicate("░", empty)} #{color}"
  end

  defp format_num(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_num(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_num(n), do: "#{n}"
end
