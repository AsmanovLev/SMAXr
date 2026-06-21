defmodule Smaxr.Tools.EvalTest do
  use ExUnit.Case, async: false

  alias Smaxr.Tools.Eval

  test "evaluates plain expression" do
    assert {:ok, out} = Eval.call(%{"code" => "1 + 2"})
    assert out =~ "3"
  end

  test "compiles and loads a defmodule into the running BEAM" do
    suffix = System.unique_integer([:positive])
    name = :"SmaxrTest_EvalModule#{suffix}"

    code = """
    defmodule #{name} do
      def hello, do: "from eval"
    end
    """

    try do
      assert {:ok, out} = Eval.call(%{"code" => code})
      assert out =~ "compiled and loaded"
      assert out =~ "SmaxrTest_EvalModule"
    after
      :code.purge(name)
      :code.delete(name)
    end
  end

  test "redefines existing module on second eval" do
    suffix = System.unique_integer([:positive])
    name = :"SmaxrTest_RedefModule#{suffix}"

    try do
      first = """
      defmodule #{name} do
        def value, do: :first
      end
      """

      second = """
      defmodule #{name} do
        def value, do: :second
      end
      """

      assert {:ok, out1} = Eval.call(%{"code" => first})
      assert out1 =~ "compiled and loaded"

      assert {:ok, out2} = Eval.call(%{"code" => second})
      assert out2 =~ "compiled and loaded"
    after
      :code.purge(name)
      :code.delete(name)
    end
  end
end
