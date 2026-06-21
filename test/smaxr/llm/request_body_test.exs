defmodule Smaxr.LLMTest do
  use ExUnit.Case, async: true

  alias Smaxr.LLM.Message

  test "analyze: what does the agent send when 5 tool_uses come back?" do
    # Simulate the exact state after 2 LLM turns:
    # Turn 1: 3 tool_uses from LLM, all 3 executed
    # Turn 2: 5 tool_uses from LLM, capped to 3, all 3 executed

    history = [Message.user("explore")]

    t1 = [
      %{"id" => "call_00_aaa", "type" => "function", "function" => %{"name" => "list_dir", "arguments" => "{}"}},
      %{"id" => "call_01_bbb", "type" => "function", "function" => %{"name" => "find_files", "arguments" => "{}"}},
      %{"id" => "call_02_ccc", "type" => "function", "function" => %{"name" => "find_files", "arguments" => "{}"}}
    ]

    history =
      history ++
        [
          Message.assistant_with_thinking("text1", t1, "think1", "sig1"),
          Message.tool_results([
            {"r1", "call_00_aaa", "list_dir"},
            {"r2", "call_01_bbb", "find_files"},
            {"r3", "call_02_ccc", "find_files"}
          ])
        ]

    t2_raw = [
      %{"id" => "call_00_ddd", "type" => "function", "function" => %{"name" => "read_file", "arguments" => "{}"}},
      %{"id" => "call_01_eee", "type" => "function", "function" => %{"name" => "read_file", "arguments" => "{}"}},
      %{"id" => "call_02_fff", "type" => "function", "function" => %{"name" => "read_file", "arguments" => "{}"}},
      %{"id" => "call_03_ggg", "type" => "function", "function" => %{"name" => "read_file", "arguments" => "{}"}},
      %{"id" => "call_04_hhh", "type" => "function", "function" => %{"name" => "read_file", "arguments" => "{}"}}
    ]

    t2_capped = Enum.take(t2_raw, 3)

    history =
      history ++
        [
          Message.assistant_with_thinking("text2", t2_capped, "think2", "sig2"),
          Message.tool_results([
            {"r4", "call_00_ddd", "read_file"},
            {"r5", "call_01_eee", "read_file"},
            {"r6", "call_02_fff", "read_file"}
          ])
        ]

    # Show what the Anthropic adapter would serialize
    {dcp_msgs, _} = Smaxr.DCP.apply_strategies(history)

    IO.puts("\n=== History (after DCP) ===")
    Enum.each(dcp_msgs, fn m ->
      tool_ids =
        case m do
          %{role: :tool, tool_results: tr} when is_list(tr) -> Enum.map(tr, fn {_, id, _} -> id end)
          %{tool_calls: tc} when is_list(tc) -> Enum.map(tc, & &1["id"])
          _ -> []
        end

      IO.puts("  role=#{m.role} tool_ids=#{inspect(tool_ids)}")
    end)

    # Now build the actual body that would be sent
    sys = Message.system("system")
    body = build_request_body(sys, dcp_msgs)

    # Show messages
    messages = body["messages"]
    IO.puts("\n=== Request body (messages) ===")
    Enum.with_index(messages)
    |> Enum.each(fn {m, i} ->
      content_str =
        case m["content"] do
          str when is_binary(str) -> str
          blocks when is_list(blocks) ->
            blocks
            |> Enum.map(fn b ->
              case b do
                %{"type" => "tool_use", "id" => id} -> "tool_use(#{id})"
                %{"type" => "tool_result", "tool_use_id" => id} -> "tool_result(#{id})"
                %{"type" => "text", "text" => t} -> "text(#{String.slice(t, 0, 30)})"
                %{"type" => "thinking"} -> "thinking"
                _ -> "other"
              end
            end)
            |> Enum.join(", ")
        end
      IO.puts("  msg[#{i}] role=#{m["role"]} #{content_str}")
    end)
  end

  defp build_request_body(sys, messages) do
    sys_text =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map_join("\n", & &1.content)

    chat_msgs =
      messages
      |> Enum.filter(&(&1.role != :system))
      |> Enum.map(&to_api_map/1)

    %{
      "model" => "test",
      "system" => sys_text,
      "messages" => chat_msgs
    }
  end

  defp to_api_map(%Message{role: :tool, tool_results: [_ | _] = results}) do
    blocks =
      Enum.map(results, fn {content, id, _name} ->
        %{"type" => "tool_result", "tool_use_id" => id || "tool_unknown", "content" => content || ""}
      end)
    %{"role" => "user", "content" => blocks}
  end
  defp to_api_map(%Message{role: r, content: c, tool_calls: tcs, tool_call_id: tci}) do
    cond do
      r == :tool ->
        %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => tci || "tool_unknown", "content" => c || ""}]}
      tcs != nil and tcs != [] ->
        blocks = if c && c != "", do: [%{"type" => "text", "text" => c}], else: []
        blocks = blocks ++ Enum.map(tcs, fn tc ->
          %{"type" => "tool_use", "id" => tc["id"], "name" => tc["function"]["name"], "input" => parse_args(tc["function"]["arguments"])}
        end)
        %{"role" => "assistant", "content" => blocks}
      true -> %{"role" => Atom.to_string(r), "content" => c || ""}
    end
  end

  defp parse_args(json) do
    case Jason.decode(json) do
      {:ok, d} -> d
      _ -> %{}
    end
  end
end
