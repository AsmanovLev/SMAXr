defmodule Smaxr.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible chat completions via Req.

  Supports any provider with an OpenAI-compatible endpoint (OpenCode,
  OpenAI, Anthropic, local models, etc.).

  ## Config

      config :smaxr, Smaxr.LLM.OpenAI,
        base_url: "https://opencode.ai/zen/go/v1",
        api_key: "sk-...",
        default_model: "kimi-k2.6",
        proxy: "socks5h://127.0.0.1:10808"

  Uses Req for HTTP. Falls back to `System.cmd("curl", ...)` for SOCKS
  proxy if configured (Req doesn't support SOCKS5 natively).
  """

  alias Smaxr.LLM.Message

  @default_base_url "https://opencode.ai/zen/go/v1"

  @spec call(String.t(), [Message.t()], keyword()) :: {:ok, Message.t(), map()} | {:error, term()}
  def call(model, messages, opts \\ []) do
    request_fn = Keyword.get(opts, :request_fn)
    do_call(model, messages, opts, request_fn)
  end

  defp do_call(model, messages, opts, _) do
    base_url = get_config(:base_url, @default_base_url)
    api_key = get_config(:api_key, "")
    proxy = get_config(:proxy, "")
    url = "#{base_url}/chat/completions"

    body = build_body(model, messages, opts)
    json_body = Jason.encode!(body)

    headers = [{"Content-Type", "application/json"}]
    headers = if api_key != "", do: headers ++ [{"Authorization", "Bearer #{api_key}"}], else: headers

    case do_post(url, headers, json_body, proxy) do
      {:ok, result} -> parse_result(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_body(model, messages, opts) do
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        messages: messages |> Enum.flat_map(&to_message_map/1),
        stream: Keyword.get(opts, :stream, false),
        max_tokens: Keyword.get(opts, :max_tokens)
      }
      |> then(fn b -> if is_nil(b.max_tokens), do: Map.delete(b, :max_tokens), else: b end)

    if tools != [] and is_list(tools) do
      openai_tools =
        Enum.map(tools, fn t ->
          function = t["function"] || t[:function]
          %{
            type: "function",
            function: %{
              name: function["name"] || function[:name],
              description: function["description"] || function[:description] || "",
              parameters: function["parameters"] || function[:parameters] || %{"type" => "object"}
            }
          }
        end)
      Map.put(body, :tools, openai_tools)
    else
      body
    end
  end

  # Convert Message to OpenAI-format message map. Handles tool_results
  # by emitting one "tool" role message per result (OpenAI spec).
  defp to_message_map(%Message{role: :tool, tool_results: [_ | _] = results}) do
    Enum.map(results, fn {content, id, name} ->
      %{
        role: "tool",
        tool_call_id: id || "tool_unknown",
        name: name,
        content: content || ""
      }
    end)
  end
  # IMPORTANT: must return a LIST, not a map. Enum.flat_map treats any
  # Enumerable as flat, and maps are Enumerable — so a map return value
  # would be coerced via Map.to_list into [{"k","v"}, ...] tuples, which
  # Jason cannot encode. Wrap the single map in a 1-element list.
  defp to_message_map(%Message{} = m), do: [Message.to_map(m)]

  defp parse_result(%{"choices" => [choice | _], "usage" => usage}) do
    raw_tc = choice["message"]["tool_calls"]
    tool_calls = if raw_tc == [], do: nil, else: raw_tc

    # Some models (deepseek-v4-flash, etc.) embed their thinking inside the
    # content as a <think>…</think> block. Strip it so the user only sees
    # the actual answer.
    raw_content = choice["message"]["content"] || ""
    content = strip_thinking(raw_content)

    msg = %Message{
      role: :assistant,
      content: content,
      tool_calls: tool_calls
    }
    {:ok, msg, usage || %{}}
  end

  defp parse_result(%{"error" => err}) do
    {:error, err["message"] || "API error"}
  end

  defp parse_result(other) do
    {:error, "unexpected response: #{inspect(other)}"}
  end

  defp strip_thinking(text) when is_binary(text) do
    Regex.replace(~r/<think>[\s\S]*?<\/think>/, text, "")
    |> String.trim()
  end
  defp strip_thinking(other), do: other || ""

  @spec models() :: [String.t()]
  def models do
    base_url = get_config(:base_url, @default_base_url)
    api_key = get_config(:api_key, "")
    proxy = get_config(:proxy, "")
    url = "#{base_url}/models"

    auth_headers = if api_key != "", do: [{"Authorization", "Bearer #{api_key}"}], else: []
    result = do_get(url, [{"Content-Type", "application/json"} | auth_headers], proxy)

    case result do
      {:ok, %{"data" => data}} when is_list(data) ->
        Enum.map(data, & &1["id"])

      _ ->
        []
    end
  end

  # HTTP via curl. Req was unreliable with some providers (MLX server
  # returning 401 via Req, works fine with curl). We use curl for all
  # requests by default now.
  defp do_post(url, headers, body, _proxy), do: curl_post(url, headers, body)

  defp do_get(url, headers, _proxy), do: curl_get(url, headers)

  # curl is used for all HTTP requests.
  defp curl_post(url, headers, body) do
    tmp = Path.join(System.tmp_dir!(), "smaxr_#{System.unique_integer([:positive])}.json")
    File.write!(tmp, body)

    try do
      args = ["-s", "-m", "60", "--data-binary", "@" <> tmp] ++ header_args(headers) ++ [url]
      case safe_curl(args) do
        {:ok, out} -> decode_json(out)
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp)
    end
  end

  defp curl_get(url, headers) do
    case safe_curl(["-s", "-m", "15"] ++ header_args(headers) ++ [url]) do
      {:ok, out} -> decode_json(out)
      {:error, reason} -> {:error, reason}
    end
  end

  defp header_args(headers) do
    Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end)
  end

  defp safe_curl(args) do
    try do
      case System.cmd("curl", args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, "curl #{code}: #{String.slice(out, 0, 200)}"}
      end
    rescue
      e in ErlangError ->
        {:error, "curl not available: #{inspect(e.reason)}"}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      _ -> {:error, "decode: #{String.slice(body, 0, 200)}"}
    end
  end

  defp get_config(key, default) do
    Application.get_env(:smaxr, Smaxr.LLM.OpenAI, [])
    |> Keyword.get(key, default)
  end
end
