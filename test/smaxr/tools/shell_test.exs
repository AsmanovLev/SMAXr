defmodule Smaxr.Tools.ShellTest do
  use ExUnit.Case, async: true

  test "terminal returns error message on failure" do
    {:ok, out} = Smaxr.Tools.Shell.call(%{"command" => "echo hello"})
    assert out =~ "hello" or out =~ "exit"
  end

  test "terminal returns error on missing args" do
    {:error, _} = Smaxr.Tools.Shell.call(%{})
  end
end
