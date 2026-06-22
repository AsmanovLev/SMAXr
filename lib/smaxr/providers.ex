defmodule Smaxr.Providers do
  @moduledoc """
  Provider registry. Reads configured providers from application config.

  Configuration in config.exs / dev.exs:

      config :smaxr, Smaxr.Providers,
        providers: [
          %{
            id: "openai",
            label: "OpenAI / OpenCode",
            module: Smaxr.LLM.OpenAI
          },
          %{
            id: "anthropic",
            label: "Anthropic / OpenModel",
            module: Smaxr.LLM.Anthropic
          }
        ]

  API (parallel to Smaxr.Models):

      Smaxr.Providers.list()
      Smaxr.Providers.current()
      Smaxr.Providers.set_current(id)
      Smaxr.Providers.find(query)
      Smaxr.Providers.valid?(id)
  """

  @doc """
  Return all configured providers as a list of maps:

      %{id: String.t(), label: String.t(), module: module(), index: pos_integer()}
  """
  @spec list() :: [%{id: String.t(), label: String.t(), module: module(), index: pos_integer()}]
  def list do
    Application.get_env(:smaxr, Smaxr.Providers, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} ->
      %{
        id: p[:id] || "provider_#{i}",
        label: p[:label] || p[:id] || "Provider #{i}",
        module: p[:module],
        index: i
      }
    end)
  end

  @doc """
  Return the id of the current provider from app env.
  Defaults to `"openai"`.
  """
  @spec current() :: String.t()
  def current do
    Application.get_env(:smaxr, :llm_provider, "openai")
  end

  @doc """
  Set the current provider by id. Returns `:ok` or `{:error, :unknown_provider}`.
  """
  @spec set_current(String.t()) :: :ok | {:error, :unknown_provider}
  def set_current(id) when is_binary(id) do
    if valid?(id) do
      Application.put_env(:smaxr, :llm_provider, id)
      :ok
    else
      {:error, :unknown_provider}
    end
  end

  @doc """
  Find a provider by:
    * exact id                   -> the provider
    * index in the list (1..N)   -> provider at that position
    * substring / label fragment -> the first match
    * "current" or nil/""        -> current provider
  """
  @spec find(String.t() | nil) :: %{id: String.t(), label: String.t(), module: module()} | nil
  def find(query) do
    providers = list()
    q = (query || "") |> to_string() |> String.trim()

    cond do
      q == "" or String.downcase(q) in ~w(current default) ->
        find_by_id(providers, current())

      true ->
        case find_by_id(providers, q) do
          nil ->
            case Integer.parse(q) do
              {n, ""} when n >= 1 and n <= length(providers) ->
                Enum.at(providers, n - 1)

              _ ->
                Enum.find(providers, fn p ->
                  String.contains?(String.downcase(p.id), String.downcase(q)) or
                    (p.label && String.contains?(String.downcase(p.label), String.downcase(q)))
                end)
            end

          m ->
            m
        end
    end
  end

  @doc """
  Check if a provider id is in the known set.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(id) when is_binary(id) do
    Enum.any?(list(), fn p -> p.id == id end)
  end

  ## Private

  defp find_by_id(providers, id) do
    Enum.find(providers, fn p -> p.id == id end)
  end
end
