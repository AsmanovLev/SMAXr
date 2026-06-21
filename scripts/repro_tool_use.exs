defmodule Repro do
  alias Smaxr.LLM.Message
  alias Smaxr.LLM.Anthropic

  def run do
    # Make Anthropic's message_to_map visible to us
    Code.ensure_loaded(Smaxr.LLM.Anthropic)
    {:ok, _} = Code.eval_string("""
    defmodule Smaxr.LLM.Anthropic do
      def debug_message_to_map(msg) do
        # Same logic as message_to_map but callable
        case msg do
          %{role: :tool, tool_results: [_ | _] = results} ->
            blocks = Enum.map(results, fn {content, id, _name} ->
              %{type: :tool_result, tool_use_id: id || "tool_unknown", content: content || ""}
            end)
            %{role: :user, content: blocks}
          %{role: r, content: c, tool_calls: tcs, tool_call_id: tci, thinking: t, signature: s} ->
            cond do
              r == :tool ->
                %{role: :user, content: [%{type: :tool_result, tool_use_id: tci || "tool_unknown", content: c || ""}]}
              tcs != nil and tcs != [] ->
                blocks = if c && c != "", do: [%{type: :text, text: c}], else: []
                blocks = if t && s, do: [%{type: :thinking, thinking: t, signature: s} | blocks], else: blocks
                blocks = blocks ++ Enum.map(tcs, fn tc ->
                  %{type: :tool_use, id: tc["id"], name: tc["function"]["name"], input: Smaxr.LLM.Anthropic.safe_decode(tc["function"]["arguments"])}
                end)
                %{role: :assistant, content: blocks}
              true -> %{role: r, content: c || ""}
            end
        end
      end

      def safe_decode(json) do
        case Jason.decode(json) do
          {:ok, d} -> d
          _ -> %{}
        end
      end
    end
    """)
    IO.puts("=== Reproduce tool_use imbalance ===")

    sys = Message.system("You are SMAXr.")

    # Simulate the actual scenario:
    # Turn 1: user asks, LLM returns 3 tool_uses, we cap to 3, execute, push results
    # Turn 2: LLM returns 5 tool_uses, we cap to 3, execute, push results
    # Turn 3: Send next request — this should fail

    history = [sys, Message.user("explore the project")]

    # Turn 1: 3 tool_uses from LLM (simulated)
    t1_tool_calls = [
      %{
        "id" => "call_00_aaa",
        "type" => "function",
        "function" => %{"name" => "list_dir", "arguments" => "{}"}
      },
      %{
        "id" => "call_01_bbb",
        "type" => "function",
        "function" => %{"name" => "find_files", "arguments" => "{}"}
      },
      %{
        "id" => "call_02_ccc",
        "type" => "function",
        "function" => %{"name" => "find_files", "arguments" => "{}"}
      }
    ]

    history =
      history ++
        [
          Message.assistant_with_thinking("", t1_tool_calls, "thinking1", "sig1"),
          Message.tool_results([
            {"r1", "call_00_aaa", "list_dir"},
            {"r2", "call_01_bbb", "find_files"},
            {"r3", "call_02_ccc", "find_files"}
          ])
        ]

    # Turn 2: 5 tool_uses from LLM, we cap to 3
    t2_tool_calls = [
      %{
        "id" => "call_00_ddd",
        "type" => "function",
        "function" => %{"name" => "read_file", "arguments" => "{}"}
      },
      %{
        "id" => "call_01_eee",
        "type" => "function",
        "function" => %{"name" => "read_file", "arguments" => "{}"}
      },
      %{
        "id" => "call_02_fff",
        "type" => "function",
        "function" => %{"name" => "read_file", "arguments" => "{}"}
      },
      %{
        "id" => "call_03_ggg",
        "type" => "function",
        "function" => %{"name" => "read_file", "arguments" => "{}"}
      },
      %{
        "id" => "call_04_hhh",
        "type" => "function",
        "function" => %{"name" => "read_file", "arguments" => "{}"}
      }
    ]

    # Cap to 3 (like agent does)
    capped = Enum.take(t2_tool_calls, 3)

    history =
      history ++
        [
          Message.assistant_with_thinking("", capped, "thinking2", "sig2"),
          Message.tool_results([
            {"r4", "call_00_ddd", "read_file"},
            {"r5", "call_01_eee", "read_file"},
            {"r6", "call_02_fff", "read_file"}
          ])
        ]

    IO.puts("History length: #{length(history)}")
    IO.puts("--- Messages in history ---")
    for m <- history do
      IO.puts(
        "  role=#{m.role} content=#{inspect(String.slice(m.content || "", 0, 50))} tool_calls=#{length(m.tool_calls || [])} tool_results=#{length(m.tool_results || [])}"
      )
    end

    # Now serialize what would be sent to API
    IO.puts("--- After DCP ---")
    {dcp_msgs, _nudge} = Smaxr.DCP.apply_strategies(history)
    IO.puts("After DCP length: #{length(dcp_msgs)}")
    for m <- dcp_msgs do
      IO.puts(
        "  role=#{m.role} content=#{inspect(String.slice(m.content || "", 0, 50))} tool_calls=#{length(m.tool_calls || [])} tool_results=#{length(m.tool_results || [])}"
      )
    end

    # Build body like anthropic.ex does
    IO.puts("--- Build body via Anthropic.build_body ---")
    body = build_body_for_inspect(sys, dcp_msgs, [])
    IO.puts(Jason.encode!(body, pretty: true))
  end

  def build_body_for_inspect(sys, messages, tools) do
    # Mimic what anthropic.ex:build_body does
    sys_text =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map_join("\n", & &1.content)

    chat_msgs =
      messages
      |> Enum.filter(&(&1.role != :system))
      |> Enum.map(&Smaxr.LLM.Anthropic.__build_for_inspect__/1)

    %{model: "test", max_tokens: 4096, messages: chat_msgs, system: sys_text}
  end
end

Repro.run()
