defmodule FakeTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  use Fake

  defmodule Original do
    @callback my_function(x :: integer()) :: atom()
    def my_function(1), do: :my_function
  end

  defmodule Helper do
    def my_helper_function, do: :my_helper_function
  end

  test "a fake can define a function from the original's behaviour" do
    module =
      fake Original do
        def my_function(1), do: :overridden_function
      end

    assert module.my_function(1) == :overridden_function
  end

  test "not supposed to define a function that's not in the original's behaviour" do
    assert capture_io(:stderr, fn ->
             module =
               fake Original do
                 def unknown_function(1), do: :unknown_function
               end

             module.unknown_function(1)
           end) =~
             ~r(warning:.*got.*@impl.*FakeTest.Original.*for function unknown_function/1 but this behaviour does not specify such callback.)
  end

  test "a fake may define a private function that's not in the original's behaviour" do
    module =
      fake Original do
        defp my_private_function, do: :my_private_function
        def my_function(1), do: my_private_function()
      end

    assert module.my_function(1) == :my_private_function
  end

  test "a fake may import a helper function" do
    module =
      fake Original do
        import Helper, only: [my_helper_function: 0]
        def my_function(1), do: my_helper_function()
      end

    assert module.my_function(1) == :my_helper_function
  end

  test "error when Fake.verify/1 is called unless the fake function has been called" do
    module =
      fake Original do
        def my_function(1), do: :ok
      end

    try do
      Fake.verify(pid_to_atom(self()), %{
        case: FakeTest,
        file: "test/fake_test.exs",
        line: 32,
        module: FakeTest,
        test: :"test error when Fake.verify/1 is called unless the fake function has been called"
      })

      flunk("Should have failed the test because f/1 was never called")
    rescue
      error in [ExUnit.MultiError] ->
        assert error == %ExUnit.MultiError{
                 errors: [
                   {:error,
                    %ExUnit.AssertionError{
                      expr: "FakeTest.Original.my_function/1",
                      message: "Implemented fake function(s) have not been called"
                    },
                    [{FakeTest.Original, :my_function, 1, [file: "test/fake_test.exs", line: 59]}]}
                 ]
               }

      error ->
        flunk("Unexpected error: #{inspect(error)}")
    end

    module.my_function(1)
  end
end
