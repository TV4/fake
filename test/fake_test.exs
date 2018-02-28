defmodule FakeTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  use Fake

  defmodule Original do
    @callback f(x :: integer()) :: :ok | :not_ok
    def f(1), do: :not_ok
  end

  test "a fake can define a function from the original's behaviour" do
    module =
      fake Original do
        def f(1), do: :ok
      end

    assert module.f(1) == :ok
  end

  test "not supposed to define a function that's not in the original's behaviour" do
    assert capture_io(:stderr, fn ->
             module =
               fake Original do
                 def g(1), do: :ok
               end

             module.g(1)
           end) =~
             ~r(warning:.*got.*@impl.*FakeTest.Original.*for function g/1 but this behaviour does not specify such callback.)
  end

  test "error when Fake.verify/1 is called unless the fake function has been called" do
    module =
      fake Original do
        def f(1), do: :ok
      end

    try do
      Fake.verify(Process.get(:fake_registry))

      flunk("Should have failed the test because f/1 was never called")
    rescue
      error in [ExUnit.AssertionError] ->
        assert error.message ==
                 "Implemented fake function(s) have not been called:\n  * Elixir.FakeTest.Original.f(1)"

      error ->
        flunk("Unexpected error: #{inspect(error)}")
    end

    module.f(1)
  end
end
