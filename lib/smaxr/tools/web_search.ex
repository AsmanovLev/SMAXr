defmodule Smaxr.Tools.WebSearch do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web via DuckDuckGo (text only, no JS)."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        query: %{type: :string, description: "Search query"}
      },
      required: ["query"]
    }
  end

  @impl true
  def call(%{"query" => query}) do
    url = "https://html.duckduckgo.com/html/?q=#{URI.encode(query)}"

    case Req.get(url) do
      {:ok, %Req.Response{body: body}} when is_binary(body) ->
        links =
          body
          |> extract_links()
          |> Enum.take(10)
          |> Enum.with_index(1)
          |> Enum.map(fn {{title, link}, i} -> "#{i}. #{title}\n   #{link}" end)
          |> Enum.join("\n\n")

        if links == "", do: {:ok, "no results"}, else: {:ok, links}

      {:error, reason} ->
        {:error, "web_search: #{inspect(reason)}"}
    end
  end

  def call(_), do: {:error, "missing 'query' argument"}

  defp extract_links(html) do
    Regex.scan(~r/<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)<\/a>/, html)
    |> Enum.map(fn [_, href, text] -> {text, href} end)
  end
end
