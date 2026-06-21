defmodule Smaxr.InspectHelpers do
  @moduledoc false
  # Helpers used by `eval` in the Smaxr shell. Kept here because the
  # eval channel cannot reliably expand self-recursive anonymous fns
  # (`f.(x, ks)`) — see elixir_expand.erl:510 mapfold issue.

  @redact_keys ~w(token api_key password secret)

  def redact(v), do: redact(v, @redact_keys)

  def redact(v, ks) when is_map(v) do
    Map.new(v, fn {k, val} ->
      k_s = k |> to_string() |> String.downcase()
      cond do
        Enum.any?(ks, &String.contains?(k_s, &1)) ->
          {k, "[REDACTED #{byte_size(:erlang.term_to_binary(val))} bytes]"}

        true ->
          {k, redact(val, ks)}
      end
    end)
  end

  def redact(v, ks) when is_list(v) do
    if Keyword.keyword?(v) do
      Map.new(v, &redact_kw/1) |> redact(ks)
    else
      Enum.map(v, &redact(&1, ks))
    end
  end

  def redact(v, _ks), do: v

  defp redact_kw({k, v}), do: {k, redact(v)}

  def relevant_env do
    System.get_env()
    |> Enum.filter(fn {k, _v} ->
      ks = String.downcase(k)

      Enum.any?(["token", "key", "smaxr", "telegram", "socks"], &String.contains?(ks, &1))
    end)
    |> Map.new(fn {k, v} -> {k, byte_size(v)} end)
  end

  def smaxr_modules do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Smaxr"))
    |> Enum.sort()
    |> Enum.map(&Atom.to_string/1)
  end

  def runtime_snapshot do
    Application.load(:smaxr)

    %{
      app_env: Application.get_all_env(:smaxr) |> Enum.into(%{}, &redact_kw/1),
      konsolidator_env: Application.get_all_env(:konsolidator) |> Enum.into(%{}, &redact_kw/1),
      llm_openai_config: redact(Application.get_env(:smaxr, Smaxr.LLM.OpenAI)),
      llm_anthropic_config: redact(Application.get_env(:smaxr, Smaxr.LLM.Anthropic)),
      llm_default_model: Application.get_env(:smaxr, :default_model),
      llm_provider: Application.get_env(:smaxr, :llm_provider),
      data_dir: Application.get_env(:smaxr, :data_dir),
      mcp_servers: Application.get_env(:smaxr, :mcp_servers, []),
      telegram_adapters:
        Application.get_env(:konsolidator, :adapters, [])
        |> Enum.map(&inspect/1),
      otp: System.otp_release(),
      elixir: System.version(),
      erts: :erlang.system_info(:version),
      arch: :erlang.system_info(:system_architecture),
      hostname: (:inet.gethostname() |> elem(1) |> List.to_string()),
      schedulers: :erlang.system_info(:schedulers),
      run_queue: :erlang.statistics(:run_queue),
      procs: :erlang.system_info(:process_count),
      mem_total: :erlang.memory(:total),
      mem_ets: :erlang.memory(:ets),
      smaxr_modules: smaxr_modules(),
      relevant_env: relevant_env()
    }
  end
end
