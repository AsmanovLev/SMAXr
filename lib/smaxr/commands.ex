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
      "clear" => &cmd_clear/2,
      "workdir" => &cmd_workdir/2,
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
      "queue" => &cmd_queue/2,
      "gitsha" => &cmd_gitsha/2,
      "gitlog" => &cmd_gitlog/2,
      "gitdiff" => &cmd_gitdiff/2,
      "status" => &cmd_status/2
    }
  end

  @whitelist MapSet.new([
    "help", "sessions", "dcp", "compress", "tools", "trace", "version",
    "workdir", "model", "models", "provider", "providers", "system",
    "maxsteps", "queue", "gitsha", "gitlog", "gitdiff", "status"
  ])

  def whitelisted?(cmd), do: MapSet.member?(@whitelist, cmd)

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

  # /new — create a new named session
  def cmd_new(_, state) do
    names = Smaxr.Store.list_sessions(state.user_id) |> Enum.map(& &1.name)
    name = unique_name(names, "default")

    Smaxr.Store.set_active(state.user_id, name)

    new_state =
      state
      |> Map.put(:session_name, name)
      |> Map.put(:messages, [])
      |> Map.put(:message_count, 0)
      |> Map.put(:dcp_state, nil)
      |> Map.put(:workdir, default_workdir())

    {:handled, "✨ New session: #{name}", new_state}
  end

  # /switch <name> — switch to existing session
  def cmd_switch(args, state) do
    name = if args != "", do: String.trim(args), else: "default"

    case Smaxr.Store.get_session(state.user_id, name) do
      {:ok, data} ->
        Smaxr.Store.set_active(state.user_id, name)
        data = Map.drop(data, [:updated_at, :session_name])
        new_state = struct(state, data)
        {:handled, "Switched to #{name}", Map.put(new_state, :session_name, name)}

      {:error, _} ->
        {:handled, "Session '#{name}' not found", state}
    end
  end

  # /rename [name] — rename current session
  def cmd_rename(args, state) do
    name = String.trim(args)

    name =
      if name == "" do
        "session-#{:erlang.unique_integer([:positive])}"
      else
        name
      end

    names = Smaxr.Store.list_sessions(state.user_id) |> Enum.map(& &1.name)

    if name in names do
      {:handled, "Session '#{name}' already exists", state}
    else
      Smaxr.Store.delete_session(state.user_id, state.session_name)
      Smaxr.Store.set_active(state.user_id, name)
      {:handled, "Renamed to #{name}", Map.put(state, :session_name, name)}
    end
  end

  # /delete [name] — delete a session
  def cmd_delete(args, state) do
    name = if args != "", do: String.trim(args), else: state.session_name
    list = Smaxr.Store.list_sessions(state.user_id)

    if length(list) <= 1 do
      {:handled, "Cannot delete the only session", state}
    else
      Smaxr.Store.delete_session(state.user_id, name)

      if name == state.session_name do
        remaining = Enum.reject(list, &(&1.name == name))
        latest = Enum.max_by(remaining, & &1.updated_at)
        Smaxr.Store.set_active(state.user_id, latest.name)
        {:ok, data} = Smaxr.Store.get_session(state.user_id, latest.name)
        data = Map.drop(data, [:updated_at, :session_name])
        new_state = struct(state, data)
        {:handled, "Deleted '#{name}', switched to '#{latest.name}'",
         Map.put(new_state, :session_name, latest.name)}
      else
        {:handled, "Deleted '#{name}'", state}
      end
    end
  end

  # /sessions — list sessions
  def cmd_sessions(_, state) do
    list = Smaxr.Store.list_sessions(state.user_id)

    if list == [] do
      count = state.message_count || length(state.messages)
      model = state.model || Smaxr.Models.current()
      provider = state.provider || Smaxr.Providers.current()
      {:handled, "Active session.\nmessages: #{count}\nmodel: #{model}\nprovider: #{provider}\n", state}
    else
      current = state.session_name
      rows =
        Enum.map(list, fn s ->
          marker = if s.name == current, do: "★", else: " "
          "#{marker}  #{s.name}  (#{s.message_count} msgs)"
        end)

      {:handled, "Sessions:\n#{Enum.join(rows, "\n")}", state}
    end
  end

  # /clear — wipe messages in current session
  def cmd_clear(_, state) do
    {:handled, "🗑 Session cleared.",
     state |> Map.put(:messages, []) |> Map.put(:message_count, 0) |> Map.put(:dcp_state, nil)}
  end

  # /workdir [path] — show or set working directory
  def cmd_workdir(args, state) do
    case String.trim(args) do
      "" ->
        wd = state.workdir || default_workdir()
        {:handled, "workdir: #{wd}", state}

      path ->
        abs_path = Path.absname(path)

        if File.dir?(abs_path) do
          {:handled, "workdir set to #{abs_path}", Map.put(state, :workdir, abs_path)}
        else
          {:handled, "directory does not exist: #{abs_path}", state}
        end
    end
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

  # /dcp — toggle DCP. Off by default; on means the model can use the
  # `compress` tool to replace closed ranges with summaries. We also
  # run the server-side heuristics (token budget, dedup tool cycles,
  # tombstones) on every call.
  def cmd_dcp(args, state) do
    arg = String.trim(args)

    cond do
      arg in ~w(on enable 1 true yes) ->
        Application.put_env(:smaxr, :dcp_enabled, true)
        {:handled, "DCP enabled (model-driven + server-side heuristics).", state}

      arg in ~w(off disable 0 false no) ->
        Application.put_env(:smaxr, :dcp_enabled, false)
        {:handled, "DCP disabled.", state}

      true ->
        cur = Application.get_env(:smaxr, :dcp_enabled, false)
        {:handled, "DCP is currently #{if cur, do: "ON", else: "OFF"}.\nUse `/dcp on` or `/dcp off`.", state}
    end
  end

  # /compress — manual trigger of DCP compression via the `compress` tool
  # isn't a direct command (the model decides when to use it). This
  # command reports whether the model has a compress tool registered
  # in the current request.
  def cmd_compress(_, state) do
    enabled = Application.get_env(:smaxr, :dcp_enabled, false)
    n = length(state.messages)

    msg =
      if enabled do
        "DCP is ON. The model has access to the `compress` tool and decides " <>
          "when to call it. #{n} messages in current history."
      else
        "DCP is OFF. Enable with `/dcp on` to expose the `compress` tool " <>
          "to the model. #{n} messages in current history."
      end

    {:handled, msg, state}
  end

  # /stop — cancel the in-progress LLM turn at the next step boundary
  def cmd_stop(_, state), do: Smaxr.Agent.do_stop(state)

  # /abort — same as /stop
  def cmd_abort(_, state), do: Smaxr.Agent.do_stop(state)

  # /queue — show queue status or set mode (instant | deferred)
  def cmd_queue(args, state), do: Smaxr.Agent.do_queue(state, args)

  # /gitsha — show current git SHA
  def cmd_gitsha(_, state) do
    workdir = state.workdir || default_workdir()
    case Smaxr.Util.safe_cmd("git", ["rev-parse", "--short", "HEAD"], cd: workdir) do
      {sha, 0} -> {:handled, "git: #{String.trim(sha)}", state}
      _ -> {:handled, "git: not a git repository", state}
    end
  end

  # /gitlog [N] — show last N commits
  def cmd_gitlog(args, state) do
    n = if args != "", do: String.to_integer(args), else: 10
    workdir = state.workdir || default_workdir()
    case Smaxr.Util.safe_cmd("git", ["log", "--oneline", "-n", Integer.to_string(n)], cd: workdir) do
      {out, 0} -> {:handled, String.trim(out), state}
      _ -> {:handled, "git: log failed", state}
    end
  end

  # /gitdiff [path] — show working-tree diff
  def cmd_gitdiff(args, state) do
    workdir = state.workdir || default_workdir()
    path = String.trim(args)
    argv = if path == "", do: ["diff"], else: ["diff", "--", path]
    case Smaxr.Util.safe_cmd("git", argv, cd: workdir) do
      {out, 0} -> {:handled, if(out == "", do: "(no diff)", else: String.trim(out)), state}
      _ -> {:handled, "git: diff failed", state}
    end
  end

  # /status — show working tree status
  def cmd_status(_, state) do
    workdir = state.workdir || default_workdir()
    case Smaxr.Util.safe_cmd("git", ["status", "--porcelain"], cd: workdir) do
      {out, 0} ->
        report = if String.trim(out) == "", do: "clean", else: String.trim(out)
        {:handled, report, state}
      _ ->
        {:handled, "git: status failed", state}
    end
  end

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
    /clear — clear current session history
    /workdir [path] — show/set working directory
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

  defp unique_name(names, base, n \\ 1)

  defp unique_name(names, base, n) do
    name = if n == 1, do: base, else: "#{base}-#{n}"

    if name in names, do: unique_name(names, base, n + 1), else: name
  end

  defp default_workdir do
    Application.get_env(:smaxr, :default_workdir, File.cwd!())
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
