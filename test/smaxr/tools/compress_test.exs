defmodule Smaxr.Tools.CompressTest do
  use ExUnit.Case, async: false

  alias Smaxr.Tools.Compress

  describe "call/1" do
    test "rejects non-list content" do
      assert {:error, msg} = Compress.call(%{"topic" => "X", "content" => "not a list"})
      assert msg =~ "non-empty list"
    end

    test "rejects empty content" do
      assert {:error, msg} = Compress.call(%{"topic" => "X", "content" => []})
      assert msg =~ "non-empty list"
    end

    test "rejects missing topic" do
      assert {:error, msg} = Compress.call(%{"content" => [%{"start_id" => "m1", "end_id" => "m2", "summary" => "x"}]})
      assert msg =~ "missing"
    end

    test "rejects invalid mN format" do
      assert {:error, msg} = Compress.call(%{
        "topic" => "Test",
        "content" => [%{"start_id" => "foo", "end_id" => "m2", "summary" => "x"}]
      })
      assert msg =~ "start_id"
    end

    test "rejects start_id > end_id" do
      assert {:error, msg} = Compress.call(%{
        "topic" => "Test",
        "content" => [%{"start_id" => "m10", "end_id" => "m3", "summary" => "x"}]
      })
      assert msg =~ "start_id must be"
    end

    test "rejects empty summary" do
      assert {:error, msg} = Compress.call(%{
        "topic" => "Test",
        "content" => [%{"start_id" => "m1", "end_id" => "m2", "summary" => ""}]
      })
      assert msg =~ "summary"
    end

    test "stashes ranges in Process dict and returns ok" do
      Process.delete(:smaxr_compress)

      try do
        args = %{
          "topic" => "My topic",
          "content" => [
            %{"start_id" => "m1", "end_id" => "m3", "summary" => "First summary"},
            %{"start_id" => "m5", "end_id" => "m7", "summary" => "Second summary"}
          ]
        }
        assert {:ok, msg} = Compress.call(args)
        assert msg =~ "2 range"

        stored = Process.get(:smaxr_compress)
        assert {"My topic", ranges} = stored
        assert [{1, 3, "First summary"}, {5, 7, "Second summary"}] = ranges
      after
        Process.delete(:smaxr_compress)
      end
    end

    test "accepts plain numeric ids as well as mN" do
      Process.delete(:smaxr_compress)
      args = %{
        "topic" => "Numeric",
        "content" => [%{"start_id" => "3", "end_id" => "7", "summary" => "test"}]
      }
      # "3" without m prefix doesn't match "m..." pattern
      assert {:error, _} = Compress.call(args)
    end
  end
end
