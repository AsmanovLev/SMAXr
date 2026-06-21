defmodule Smaxr.Tool do
  @moduledoc """
  Behaviour for all tools. Each tool is a simple module.

  A tool takes a map of arguments (string keys, JSON-decoded from the
  LLM's function call) and returns `{:ok, result}` or `{:error, reason}`.

  The result is converted to a string and fed back to the LLM.
  """

  @type args :: map()
  @type result :: term()

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback call(args()) :: {:ok, result()} | {:error, term()}
end
