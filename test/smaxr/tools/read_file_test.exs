defmodule Smaxr.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  test "read_file returns content" do
    path = "test/support/fixtures/llm/chat_completion_200.json"
    {:ok, content} = Smaxr.Tools.ReadFile.call(%{"path" => path})
    assert content =~ "Hello! How can I help you"
  end

  test "read_file with offset skips lines" do
    path = "test/support/fixtures/llm/chat_completion_200.json"
    {:ok, full} = Smaxr.Tools.ReadFile.call(%{"path" => path})
    {:ok, skipped} = Smaxr.Tools.ReadFile.call(%{"path" => path, "offset" => 1})
    assert byte_size(skipped) < byte_size(full)
  end

  test "read_file with limit returns first N lines" do
    path = "test/support/fixtures/llm/chat_completion_200.json"
    {:ok, full} = Smaxr.Tools.ReadFile.call(%{"path" => path})
    {:ok, limited} = Smaxr.Tools.ReadFile.call(%{"path" => path, "limit" => 2})
    assert byte_size(limited) < byte_size(full)
    assert limited |> String.split("\n") |> length() == 2
  end

  test "read_file with offset + limit returns slice" do
    path = "test/support/fixtures/llm/chat_completion_200.json"
    {:ok, content} = Smaxr.Tools.ReadFile.call(%{"path" => path, "offset" => 0, "limit" => 1})
    assert content |> String.split("\n") |> length() == 1
  end

  test "read_file errors on missing file" do
    {:error, msg} = Smaxr.Tools.ReadFile.call(%{"path" => "/nonexistent/file"})
    assert msg =~ "read_file"
  end

  test "read_file errors on missing argument" do
    {:error, _} = Smaxr.Tools.ReadFile.call(%{})
  end
end
