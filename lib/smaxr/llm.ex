defmodule Smaxr.LLM do
  @moduledoc """
  Behaviour for the LLM backends. Each provider implements this.

  `Smaxr.LLM.OpenAI` is the primary implementation for OpenAI-compatible
  APIs (including OpenCode, OpenAI, Anthropic via proxy, etc.).
  """

  alias Smaxr.LLM.Message

  @type model :: String.t()
  @type provider :: module()

  @callback call(model(), [Message.t()], keyword()) :: {:ok, Message.t(), map()} | {:error, term()}

  @callback models() :: [String.t()]
end
