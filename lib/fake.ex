defmodule Fake do
  defmacro __using__(_) do
    quote do
      import Fake

      setup do
        {:ok, registry} = Agent.start(fn -> %{} end)
        Process.put(:fake_registry, registry)

        on_exit(fn -> Fake.verify(registry) end)
      end
    end
  end

  def verify(pid) do
    Agent.get(pid, fn state ->
      state
      |> Enum.filter(fn {_, called} -> !called end)
    end)
    |> case do
      [] ->
        :ok

      uncalled ->
        uncalled =
          Keyword.keys(uncalled)
          |> Enum.map(&"  * #{&1}")
          |> Enum.join("\n")

        ExUnit.Assertions.flunk("Implemented fake function(s) have not been called:\n#{uncalled}")
    end
  end

  def mfas(behaviour_module, implemented_functions) do
    implemented_functions
    |> Enum.map(fn {_, _, [{fun, _, args}, _]} ->
      "#{behaviour_module}.#{Macro.to_string({fun, [], args || []})}"
    end)
  end

  def impl(behaviour_module) do
    Stream.repeatedly(fn ->
      quote do
        @impl unquote(behaviour_module)
      end
    end)
  end

  def fake_module(behaviour_module) do
    random_stuff =
      :crypto.strong_rand_bytes(12)
      |> :erlang.bitstring_to_list()
      |> Enum.map(&:erlang.integer_to_binary(&1, 16))
      |> Enum.join()
      |> String.capitalize()

    :"#{behaviour_module}.Fake.#{random_stuff}"
  end

  def callbacks(behaviour_module, fake_module) do
    behaviour_module.behaviour_info(:callbacks)
    |> Enum.map(fn {callback, arity} ->
      args =
        Stream.repeatedly(fn -> Macro.var(:_, fake_module) end)
        |> Enum.take(arity)

      quote do
        def unquote(callback)(unquote_splicing(args)) do
          raise("fake function not implemented for #{unquote(callback)}/#{unquote(arity)}")
        end
      end
    end)
  end

  def decorate(behaviour_module, functions) do
    Enum.map(functions, fn {:def, context, [{fun, fc, args}, [do: body]]} ->
      {:def, context,
       [
         {fun, fc, args},
         [
           do:
             {:__block__, [],
              [
                {:call, [], ["#{behaviour_module}.#{Macro.to_string({fun, [], args || []})}"]},
                body
              ]}
         ]
       ]}
    end)
  end

  defmacro fake(behaviour, do: code) do
    behaviour_module = Macro.expand(behaviour, __CALLER__)
    fake_module = fake_module(behaviour_module)
    impl = impl(behaviour_module)

    {code, implemented_functions} =
      case code do
        nil ->
          {nil, []}

        {:__block__, context, implemented_functions} ->
          {
            {
              :__block__,
              context,
              Enum.zip(impl, decorate(behaviour_module, implemented_functions))
            },
            implemented_functions
          }

        function ->
          {{:__block__, [], Enum.zip(impl, decorate(behaviour_module, [function]))}, [function]}
      end

    mfas = mfas(behaviour_module, implemented_functions)
    state = {:%{}, [], Enum.map(mfas, &{&1, false})}

    quote do
      defmodule unquote(fake_module) do
        @behaviour unquote(behaviour_module)

        unquote(callbacks(behaviour_module, fake_module))

        defoverridable(unquote(behaviour_module))

        Agent.update(Process.get(:fake_registry), fn state ->
          Map.merge(state, unquote(state))
        end)

        def call(mfa) do
          Agent.update(Process.get(:fake_registry), fn state ->
            Map.put(state, mfa, true)
          end)
        end

        unquote(code)
      end

      unquote(fake_module)
    end
  end
end
