defmodule Smaxr.Tools.Vision do
  @behaviour Smaxr.Tool

  @impl true
  def name, do: "vision"

  @impl true
  def description, do: "Analyze an image with the vision model."

  @impl true
  def parameters do
    %{
      type: :object,
      properties: %{
        path: %{type: :string, description: "Absolute path to the image file"},
        prompt: %{type: :string, description: "Question about the image"}
      },
      required: ["path", "prompt"]
    }
  end

  @impl true
  def call(%{"path" => path, "prompt" => prompt}) do
    with {:ok, base64} <- encode_image(path) do
      msg = %{
        role: "user",
        content: [
          %{type: :text, text: prompt},
          %{type: :image_url, image_url: %{url: "data:image/jpeg;base64,#{base64}"}}
        ]
      }

      body = %{model: "mimo-v2.5", messages: [msg], stream: false, max_tokens: 1024}

      case do_post(body) do
        {:ok, text} -> {:ok, text}
        {:error, reason} -> {:error, "vision: #{reason}"}
      end
    end
  end

  def call(_), do: {:error, "missing 'path' or 'prompt'"}

  defp encode_image(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, Base.encode64(data)}
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  defp do_post(body) do
    api_key = Application.get_env(:smaxr, Smaxr.LLM.OpenAI, []) |> Keyword.get(:api_key, "")
    url = "https://opencode.ai/zen/go/v1/chat/completions"

    case Smaxr.Util.safe_cmd("curl", [
      "-s", "-m", "30",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer #{api_key}",
      "-d", Jason.encode!(body),
      url
    ]) do
      {:error, reason} ->
        {:error, reason}

      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"choices" => [c | _]}} ->
            {:ok, get_in(c, ["message", "content"]) || ""}

          {:ok, %{"error" => err}} ->
            {:error, err["message"]}

          _ ->
            {:error, "unexpected response"}
        end

      {out, code} ->
        {:error, "curl #{code}: #{String.slice(out, 0, 200)}"}
    end
  end
end

