defmodule Smaxr.Tools.FileInfoTest do
  use ExUnit.Case, async: true

  test "file_info returns metadata" do
    {:ok, info} = Smaxr.Tools.FileInfo.call(%{"path" => "test/test_helper.exs"})
    assert info =~ "test_helper.exs"
  end

  test "file_info errors on missing file" do
    {:error, _} = Smaxr.Tools.FileInfo.call(%{"path" => "/nonexistent"})
  end
end
