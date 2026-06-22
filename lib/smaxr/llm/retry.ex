defmodule Smaxr.LLM.Retry do
  @moduledoc """
  Exponential backoff retry for LLM HTTP calls.

  Retries on 429 (rate limit), 502, 503, 504 (server errors).
  Default: 4 attempts, base delay 1s, 2x multiplier, ±20% jitter.
  """

  require Logger

  @retryable_statuses [429, 502, 503, 504]

  def with_backoff(fun, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 4)
    base_ms = Keyword.get(opts, :base_ms, 1000)
    attempt(1, max, base_ms, fun)
  end

  defp attempt(n, max, base_ms, fun) when n <= max do
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> maybe_retry(n, max, base_ms, fun, reason)
    end
  end

  defp maybe_retry(n, max, base_ms, fun, reason) do
    if retryable?(reason) and n < max do
      delay = backoff_ms(n, base_ms) + jitter()
      Logger.warning("[LLM Retry] attempt #{n}/#{max} failed: #{truncate(reason)} — retrying in #{delay}ms")
      Process.sleep(delay)
      attempt(n + 1, max, base_ms, fun)
    else
      {:error, reason}
    end
  end

  defp retryable?(reason) when is_binary(reason) do
    Enum.any?(@retryable_statuses, fn code ->
      String.contains?(reason, "curl #{code}:") or
        String.contains?(reason, ":#{code},") or
        String.contains?(reason, "HTTP #{code}")
    end)
  end

  defp retryable?(_), do: false

  defp backoff_ms(n, base_ms), do: trunc(:math.pow(2, n - 1) * base_ms)

  defp jitter, do: trunc(:rand.uniform(401) - 200)

  defp truncate(s), do: String.slice(s || "", 0, 200)
end
