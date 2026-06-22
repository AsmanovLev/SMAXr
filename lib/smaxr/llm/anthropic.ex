defmodule Smaxr.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API client (also used by openmodel.ai).

  Endpoint: POST /v1/messages
  Auth: x-api-key (header)
  """

  require Logger
  alias Smaxr.LLM.Message

  @default_base_url "https://api.openmodel.ai"

  def call(model, messages, opts \\ []) do
    base_url = get_config(:base_url, @default_base_url)
    api_key = get_config(:api_key, "")
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    tools = Keyword.get(opts, :tools, [])

    body = build_body(model, messages, max_tokens, tools)
    json_body = Jason.encode!(body)

    Logger.debug("[Anthropic] request body: #{String.slice(json_body, 0, 2000)}")

    headers = [
      {"Content-Type", "application/json"},
      {"anthropic-version", "2023-06-01"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    headers = if api_key == "", do: List.delete_at(headers, 2), else: headers
    url = "#{base_url}/v1/messages"

    case Smaxr.LLM.Retry.with_backoff(fn -> curl_post(url, headers, json_body) end) do
      {:ok, result} -> parse_result(result)
      {:error, reason} -> {:error, reason}
    end
  end

  def models do
    base_url = get_config(:base_url, @default_base_url)
    api_key = get_config(:api_key, "")
    url = "#{base_url}/v1/models"
    headers = [{"Authorization", "Bearer #{api_key}"}]
    headers = if api_key == "", do: [], else: headers

    case curl_get(url, headers) do
      {:ok, %{"data" => data}} when is_list(data) ->
        Enum.map(data, & &1["id"])

      _ ->
        []
    end
  end

  defp build_body(model, messages, max_tokens, tools) do
    sys_text =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map_join("\n", & &1.content)

    chat_msgs =
      messages
      |> Enum.filter(&(&1.role != :system))
      |> Enum.map(&message_to_map/1)

    body = %{model: model, max_tokens: max_tokens, messages: chat_msgs, stream: false}
    body = if sys_text != "", do: Map.put(body, :system, sys_text), else: body

    if tools != [] and is_list(tools) do
      anthropic_tools =
        Enum.map(tools, fn t ->
          function = t["function"] || t[:function]
          %{
            name: function["name"] || function[:name],
            description: function["description"] || function[:description] || "",
            input_schema: function["parameters"] || function[:parameters] || %{"type" => "object"}
          }
        end)

      Map.put(body, :tools, anthropic_tools)
    else
      body
    end
  end

  defp message_to_map(%Message{role: :tool, tool_results: [_ | _] = results}) do
    blocks =
      Enum.map(results, fn {content, id, _name} ->
        %{type: :tool_result, tool_use_id: id || "tool_unknown", content: content || ""}
      end)
    %{role: :user, content: blocks}
  end
  defp message_to_map(%Message{role: r, content: c, tool_calls: tcs, tool_call_id: tci, thinking: t, signature: s}) do
    cond do
      r == :tool ->
        id = tci || "tool_unknown"
        %{role: :user, content: [%{type: :tool_result, tool_use_id: id, content: c || ""}]}

      tcs != nil and tcs != [] ->
        blocks = if c && c != "", do: [%{type: :text, text: c}], else: []

        # Re-add thinking block if present (required for thinking-mode models)
        blocks =
          if t && s do
            [%{type: :thinking, thinking: t, signature: s} | blocks]
          else
            blocks
          end

        blocks =
          blocks ++
            Enum.map(tcs, fn tc ->
              %{}
              |> Map.put(:type, :tool_use)
              |> Map.put(:id, tc["id"] || "tool_" <> Integer.to_string(System.unique_integer([:positive])))
              |> Map.put(:name, tc["function"]["name"])
              |> Map.put(:input, safe_decode(tc["function"]["arguments"]))
            end)

        %{role: :assistant, content: blocks}

      true ->
        %{role: r, content: c || ""}
    end
  end

  defp safe_decode(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp has_text?(blocks), do: text_of(blocks) != nil

  defp text_of(blocks) do
    Enum.find_value(blocks, fn
      %{"type" => "text", "text" => t} -> t
      _ -> nil
    end)
  end

  defp has_tool_use?(blocks) do
    Enum.any?(blocks, &(&1["type"] == "tool_use"))
  end

  @doc false
  def parse_result(%{"content" => blocks, "usage" => usage}) do
    text =
      case {has_text?(blocks), has_tool_use?(blocks)} do
        # tool_use present → text is the lead-in, default "" if no text block
        {_, true} -> text_of(blocks) || ""
        # pure text → use it
        {true, _} -> text_of(blocks)
        # only thinking (or only signature, or empty) → empty text
        # so enforce_response kicks in instead of "responding" with thinking
        _ -> ""
      end

    # Capture thinking blocks for re-sending in multi-turn conversations
    thinking_block = Enum.find(blocks, &(&1["type"] == "thinking"))
    thinking = if thinking_block, do: thinking_block["thinking"], else: nil
    signature = if thinking_block, do: thinking_block["signature"], else: nil

    tool_calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn tc ->
        %{
          "id" => tc["id"] || "tool_" <> Integer.to_string(System.unique_integer([:positive])),
          "type" => "function",
          "function" => %{
            "name" => tc["name"],
            "arguments" => Jason.encode!(tc["input"])
          }
        }
      end)

    tool_calls = if tool_calls == [], do: nil, else: tool_calls

    msg = %Message{
      role: :assistant,
      content: text,
      tool_calls: tool_calls,
      thinking: thinking,
      signature: signature
    }

    {:ok, msg, usage || %{}}
  end

  def parse_result(%{"error" => err}) do
    {:error, err["message"] || "API error"}
  end

  def parse_result(other) do
    {:error, "unexpected response: #{inspect(other)}"}
  end

  defp curl_post(url, headers, body) do
    # Write body to temp file to avoid shell escaping issues with special characters
    tmp = Path.join(System.tmp_dir!(), "smaxr_#{System.unique_integer([:positive])}.json")
    File.write!(tmp, body)

    try do
      args = ["-s", "-m", "120", "--data-binary", "@" <> tmp] ++ hdrs(headers) ++ [url]
      case safe_curl(args) do
        {:ok, out} ->
          log_raw_response(out)
          decode(out)

        {:error, reason} ->
          Logger.error("[Anthropic] curl error: #{inspect(reason)}")
          {:error, reason}
      end
    after
      File.rm(tmp)
    end
  end

  # Log the raw LLM response (truncated) to the chat log for debugging
  # empty/no-text cases. Writes to priv/smaxr/logs/llm_raw.log (one file,
  # appended, line per response).
  defp log_raw_response(out) when is_binary(out) do
    dir = Application.get_env(:smaxr, :data_dir, "priv/smaxr") |> Path.join("logs")
    File.mkdir_p!(dir)
    path = Path.join(dir, "llm_raw.log")

    truncated = if byte_size(out) > 4000, do: String.slice(out, 0, 4000) <> "...[truncated]", else: out
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(path, "=== #{ts} ===\n#{truncated}\n\n", [:append])
  rescue
    _ -> :ok
  end
  defp log_raw_response(_), do: :ok

  defp curl_get(url, headers) do
    case safe_curl(["-s", "-m", "15"] ++ hdrs(headers) ++ [url]) do
      {:ok, out} -> decode(out)
      {:error, reason} -> {:error, reason}
    end
  end

  defp hdrs(headers), do: Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end)

  defp safe_curl(args) do
    try do
      case System.cmd("curl", args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, c} -> {:error, "curl #{c}: #{String.slice(out, 0, 200)}"}
      end
    rescue
      e in ErlangError -> {:error, "curl not available: #{inspect(e.reason)}"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      _ -> {:error, "decode: #{String.slice(body, 0, 200)}"}
    end
  end

  defp get_config(key, default) do
    Application.get_env(:smaxr, Smaxr.LLM.Anthropic, [])
    |> Keyword.get(key, default)
  end
end
