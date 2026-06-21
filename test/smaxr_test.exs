defmodule SmaxrTest do
  use ExUnit.Case, async: true

  test "application starts" do
    # The application is started by mix test. Verify the supervisor is up.
    assert Process.whereis(Smaxr.Supervisor) != nil
  end

  test "konsolidator is started alongside smaxr" do
    assert Process.whereis(Konsolidator.Supervisor) != nil
  end

  test "smaxr router is running" do
    assert Process.whereis(Smaxr.Router) != nil
  end
end
