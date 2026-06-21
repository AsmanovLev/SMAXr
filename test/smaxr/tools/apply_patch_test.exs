defmodule Smaxr.Tools.ApplyPatchTest do
  use ExUnit.Case, async: false

  alias Smaxr.Tools.ApplyPatch

  setup do
    File.mkdir_p!("priv/_test")
    path = "priv/_test/patch_target.ex"

    # First version of the file (defines a function returning :first).
    File.write!(path, """
    defmodule Smaxr.Test.PatchTarget do
      def value, do: :first
    end
    """)

    # apply_patch loads the file itself; no pre-require here.
    on_exit(fn ->
      File.rm_rf!("priv/_test")
      :code.purge(Smaxr.Test.PatchTarget)
      :code.delete(Smaxr.Test.PatchTarget)
    end)

    {:ok, path: path}
  end

  test "rejects non-.ex files" do
    assert {:error, msg} = ApplyPatch.call(%{"path" => "README.md"})
    assert msg =~ "only reloads .ex files"
  end

  test "rejects missing files" do
    assert {:error, msg} = ApplyPatch.call(%{"path" => "lib/does_not_exist.ex"})
    assert msg =~ "file not found"
  end

  test "replaces module body in the running BEAM", %{path: path} do
    # First load
    {:ok, msg1} = ApplyPatch.call(%{"path" => path})
    assert msg1 =~ "reloaded"
    assert Smaxr.Test.PatchTarget.value() == :first

    # Edit source on disk
    File.write!(path, """
    defmodule Smaxr.Test.PatchTarget do
      def value, do: :second
    end
    """)

    # Hot reload — same module name, new body
    {:ok, msg2} = ApplyPatch.call(%{"path" => path})
    assert msg2 =~ "reloaded"
    assert Smaxr.Test.PatchTarget.value() == :second
  end
end
