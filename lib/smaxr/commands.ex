defmodule Smaxr.Commands do
  @moduledoc """
  Command registry. Processes Telegram-style slash commands before they
  reach the LLM.
  """

  def commands_map do
    %{
      "start" => &cmd_start/2,
      "help" => &cmd_help/2,
      "new" => &cmd_new/2,
      "switch" => &cmd_switch/2,
      "rename" => &cmd_rename/2,
      "delete" => &cmd_delete/2,
      "sessions" => &cmd_sessions/2,
      "model" => &cmd_model/2,
      "models" => &cmd_models/2,
      "provider" => &cmd_provider/2,
      "providers" => &cmd_providers/2,
      "system" => &cmd_system/2,
      "maxsteps" => &cmd_maxsteps/2,
      "tools" => &cmd_tools/2,
      "trace" => &cmd_trace/2,
      "version" => &cmd_version/2,
      "dcp" => &cmd_dcp/2,
      "compress" => &cmd_compress/2,
      "stop" => &cmd_stop/2,
      "abort" => &cmd_abort/2,
      "queue" => &cmd_queue/2
    }
  end

  @doc "Check if text starts with a '/command'. Returns {:command, args} or nil."
  def parse(text) when is_binary(text) do
    cmds = commands_map()

    case Regex.run(~r{^/(\w+)(.*)}, String.trim(text)) do
      [_, cmd_raw, args] ->
        cmd = String.downcase(cmd_raw)
        if Map.has_key?(cmds, cmd),
          do: {:command, cmd, String.trim(args)},
          else: nil

      _ ->
        nil
    end
  end

  def parse(_), do: nil

  @doc "Execute a parsed command. Returns {:handled, text, state_updates} or :passthrough."
  def execute(cmd, args, _source, state) do
    handler = Map.get(commands_map(), cmd)

    result = if handler, do: handler.(args, state), else: {:handled, "Unknown command: /#{cmd}", state}

    # Normalize {:ok, ...} to {:handled, ...}
    case result do
      {:ok, reply, new_state} -> {:handled, reply, new_state}
      other -> other
    end
  end

  # /start
  def cmd_start(_, state) do
    msg = help_text(state)
    {:handled, msg, state}
  end

  # /help
  def cmd_help(_, state) do
    {:handled, help_text(state), state}
  end

  # /new — start new session (clear messages)
  def cmd_new(_, state) do
    {:handled, "✨ New session started.", %{state | messages: [], message_count: 0}}
  end

  # /switch — placeholder (needs store)
  def cmd_switch(args, state) do
    session_id = if args != "", do: args, else: "default"
    {:handled, "session switched to #{session_id}", state}
  end

  # /rename — placeholder
  def cmd_rename(args, state) do
    name = if args != "", do: args, else: DateTime.utc_now() |> DateTime.to_string()
    {:handled, "session renamed to #{name}", state}
  end

  # /delete — placeholder
  def cmd_delete(_, state) do
    {:handled, "current session deleted. Starting fresh.", %{state | messages: [], message_count: 0}}
  end

  # /sessions — list
  def cmd_sessions(_, state) do
    count = state.message_count
    model = state.model || Smaxr.Models.current()
    provider = state.provider || Smaxr.Providers.current()
    {:handled, "Active session.\nmessages: #{count}\nmodel: #{model}\nprovider: #{provider}\n", state}
  end

  # /model — show or set (with validation against Smaxr.Models)
  def cmd_model(args, state) do
    case String.trim(args) do
      "" ->
        cur = state.model || Smaxr.Models.current()
        {:handled, "model: #{cur}\n(use `/models` to list, `/model <n|name>` to switch)", state}

      query ->
        case Smaxr.Models.find(query) do
          nil ->
            hint =
              Smaxr.Models.list()
              |> Enum.take(8)
              |> Enum.map(& &1.id)
              |> Enum.join(", ")

            {:handled,
             "❌ unknown model: #{query}\nTry `/models` (examples: #{hint}…)", state}

          %{id: id} ->
            # Set both the app-wide default AND this user's per-agent model.
            :ok = Smaxr.Models.set_current(id)
            new_state = %{state | model: id}
            {:handled, "✅ model set to #{id} (app default + this session)", new_state}
        end
    end
  end

  # /models — list known models, with optional filter
  def cmd_models(args, state) do
    case String.trim(args) do
      "refresh" ->
        case Smaxr.Models.list!() do
          list when is_list(list) ->
            {:handled, "🔄 refreshed. #{length(list)} models available.", state}

          _ ->
            {:handled, "⚠️ refresh failed (see logs)", state}
        end

      "" ->
        render_models_list(state, nil)

      filter ->
        render_models_list(state, filter)
    end
  end

  defp render_models_list(state, filter) do
    models = Smaxr.Models.list()
    current = state.model || Smaxr.Models.current()

    filtered =
      case filter do
        nil ->
          models

        f ->
          f_lower = String.downcase(f)

          Enum.filter(models, fn m ->
            String.contains?(String.downcase(m.id), f_lower) or
              String.contains?(String.downcase(m.owned_by), f_lower)
          end)
      end

    cond do
      filtered == [] ->
        {:handled, "no models match '#{filter}' (try `/models refresh`)", state}

      true ->
        rows =
          filtered
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {m, i} ->
            marker = if m.id == current, do: "★", else: " "
            "#{marker} #{String.pad_leading("#{i}", 3)}  #{String.pad_trailing(m.id, 24)}  #{m.owned_by}"
          end)

        header = "current: #{current}   total: #{length(models)} (showing #{length(filtered)})"
        footer = "\nusage: /model <number|name|family>  e.g.  /model 4   /model kimi   /model glm-5"
        {:handled, header <> "\n" <> rows <> footer, state}
    end
  end

  # /provider — show or set (with validation against Smaxr.Providers)
  def cmd_provider(args, state) do
    case String.trim(args) do
      "" ->
        cur = state.provider || Smaxr.Providers.current()
        {:handled, "provider: #{cur}\n(use `/providers` to list, `/provider <n|name>` to switch)", state}

      query ->
        case Smaxr.Providers.find(query) do
          nil ->
            hint =
              Smaxr.Providers.list()
              |> Enum.take(5)
              |> Enum.map(& "#{&1.id} (#{&1.label})")
              |> Enum.join(", ")

            {:handled,
             "❌ unknown provider: #{query}\nTry `/providers` (examples: #{hint}…)", state}

          %{id: id, label: label} ->
            :ok = Smaxr.Providers.set_current(id)
            new_state = %{state | provider: id}
            {:handled, "✅ provider set to #{id} (#{label})", new_state}
        end
    end
  end

  # /providers — list available providers
  def cmd_providers(_, state) do
    providers = Smaxr.Providers.list()
    current = state.provider || Smaxr.Providers.current()

    rows =
      providers
      |> Enum.map(fn p ->
        marker = if p.id == current, do: "★", else: " "
        "#{marker}  #{String.pad_trailing(p.id, 16)}  #{p.label}"
      end)
      |> Enum.join("\n")

    header = "current: #{current}   total: #{length(providers)}"
    footer = "\nusage: /provider <number|name>  e.g.  /provider 2   /provider anthropic"
    {:handled, header <> "\n" <> rows <> footer, state}
  end

  # /system — show system prompt
  def cmd_system(_, state) do
    prompt = get_system_prompt()
    {:handled, "system prompt:\n#{prompt}", state}
  end

  # /maxsteps — placeheld
  def cmd_maxsteps(args, state) do
    steps = if args != "", do: String.to_integer(args), else: 200
    {:handled, "max steps: #{steps}", %{state | max_steps: steps}}
  end

  # /tools — list available tools
  def cmd_tools(_, state) do
    names =
      Smaxr.Tools.available()
      |> Enum.map(& &1.name())
      |> Enum.join(", ")

    {:handled, "tools: #{names}", state}
  end

  # /trace — toggle (stub)
  def cmd_trace(_, state) do
    {:handled, "trace: on (verbose mode)", state}
  end

  # /version
  def cmd_version(_, state) do
    sha = git_sha()
    model = state.model || "?"
    provider = state.provider || Smaxr.Providers.current() || "?"
    {:handled, "SMAXr #{sha} (model: #{model}, provider: #{provider})", state}
  end

  # /dcp — DCP control (stub)
  def cmd_dcp(_, state) do
    msg = "message count: #{state.message_count}\nDCP: not yet implemented"
    {:handled, msg, state}
  end

  # /compress — compress conversation (stub)
  def cmd_compress(_, state) do
    {:handled, "compressing conversation (stub)", state}
  end

  # /stop — cancel the in-progress LLM turn at the next step boundary
  def cmd_stop(_, state), do: Smaxr.Agent.do_stop(state)

  # /abort — same as /stop
  def cmd_abort(_, state), do: Smaxr.Agent.do_stop(state)

  # /queue — show queue status or set mode (instant | deferred)
  def cmd_queue(args, state), do: Smaxr.Agent.do_queue(state, args)

  # Help text
  defp help_text(_state) do
    """
    **SMAXr** — Self-Modifying Agent written in Elixir

    /start — this message
    /help  — command list
    /new   — new session
    /switch <name> — switch session
    /rename <name> — rename session
    /delete — delete current session
    /sessions — list sessions
    /model [name] — show/set model (e.g. `/model 4`, `/model kimi`, `/model glm-5.2`)
    /models [filter|refresh] — list available models
    /provider [name] — show/set provider (e.g. `/provider anthropic`, `/provider 2`)
    /providers — list available providers
    /system — show system prompt
    /maxsteps [n] — show/set max steps
    /tools — list tools
    /trace — toggle trace
    /version — show version
    /dcp — DCP control
    /compress — compress context
    /stop — stop processing
    /abort — abort processing
    /queue — show messages waiting in the queue
    """
  end

  defp get_system_prompt do
    Application.get_env(:smaxr, Smaxr.LLM.OpenAI, [])
    |> Keyword.get(:system_prompt, "You are SMAXr, a helpful AI assistant. Be concise and efficient.")
  end

  defp git_sha do
    try do
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end
    rescue
      _ -> "unknown"
    end
  end
end
