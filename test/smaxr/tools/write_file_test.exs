defmodule Smaxr.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  setup do
    path = System.tmp_dir!() |> Path.join("smago_tool_test_#{System.unique_integer([:positive])}")
    {:ok, [tmp: path]}
  end

  test "write_file creates a file", %{tmp: path} do
    {:ok, msg} = Smaxr.Tools.WriteFile.call(%{"path" => path, "content" => "hello"})
    assert msg =~ "written"
    assert File.read!(path) == "hello"
  after
    File.rm(path)
  end

  test "write_file errors on missing args" do
    {:error, _} = Smaxr.Tools.WriteFile.call(%{"content" => "x"})
  end
end
