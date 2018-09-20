defmodule Fake do
  def pid_to_atom(pid), do: pid |> :erlang.pid_to_list() |> to_string |> String.to_atom()

  defmacro __using__(_) do
    quote do
      import Fake

      setup context do
        {:ok, registry} = Agent.start(fn -> %{} end, name: pid_to_atom(self()))

        on_exit(fn -> Fake.verify(registry, context) end)
      end
    end
  end

  def verify(pid, context \\ %{}) do
    Agent.get(pid, fn state ->
      state
      |> Enum.filter(fn {_, called} -> !called end)
      |> Keyword.keys()
    end)
    |> case do
      [] ->
        :ok

      uncalled ->
        errors =
          uncalled
          |> Enum.map(fn {name, line} ->
            [m, f, a] = Regex.run(~r/(.*)\.(.*)\/(.*)/, name, capture: :all_but_first)
            m = String.to_atom("Elixir.#{m}")
            f = String.to_atom(f)
            a = String.to_integer(a)

            {:error,
             %ExUnit.AssertionError{
               message: "Implemented fake function(s) have not been called",
               expr: name
             },
             [
               {m, f, a,
                [
                  file: Path.relative_to(context.file, File.cwd!()),
                  line: line
                ]}
             ]}
          end)

        raise ExUnit.MultiError, errors: errors
    end
  end

  defp mfas(behaviour_module, public_functions) do
    public_functions
    |> Enum.map(fn {:def, [line: line], [{fun, _, args}, _]} ->
      {Exception.format_mfa(behaviour_module, fun, length(args)), line}
    end)
  end

  defp impl(behaviour_module) do
    quote do
      @impl unquote(behaviour_module)
    end
  end

  defp fake_module(behaviour_module) do
    random_stuff =
      :crypto.strong_rand_bytes(12)
      |> :erlang.bitstring_to_list()
      |> Enum.map(&:erlang.integer_to_binary(&1, 16))
      |> Enum.join()
      |> String.capitalize()

    :"#{behaviour_module}.Fake.#{random_stuff}"
  end

  defp callbacks(behaviour_module, fake_module) do
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

  # Decorate expressions containing functions with @impl behaviour_module.
  # Keep other expressions as is.
  defp decorate(behaviour_module, expressions) do
    Enum.flat_map(expressions, fn
      public_function = {:def, context, [{fun, fc, args}, [do: body]]} ->
        [
          impl(behaviour_module),
          {:def, context,
           [
             {fun, fc, args},
             [
               do:
                 {:__block__, [],
                  [
                    {:call, [], mfas(behaviour_module, [public_function])},
                    body
                  ]}
             ]
           ]}
        ]

      otherwise ->
        [otherwise]
    end)
  end

  defp public_functions(functions) do
    Enum.filter(functions, fn
      {:def, _, _} -> true
      _ -> false
    end)
  end

  defmacro fake(behaviour, do: code) do
    behaviour_module = Macro.expand(behaviour, __CALLER__)
    fake_module = fake_module(behaviour_module)

    {code, functions} =
      case code do
        nil ->
          {nil, []}

        {:__block__, context, expressions} ->
          public_functions = public_functions(expressions)

          {
            {
              :__block__,
              context,
              decorate(behaviour_module, expressions)
            },
            public_functions
          }

        expression ->
          expressions = [expression]
          public_functions = public_functions(expressions)

          {{:__block__, [], decorate(behaviour_module, expressions)}, public_functions}
      end

    mfas = mfas(behaviour_module, functions)
    initial_state = {:%{}, [], Enum.map(mfas, &{&1, false})}

    quote do
      defmodule unquote(fake_module) do
        @behaviour unquote(behaviour_module)

        @agent_name pid_to_atom(self())

        unquote(callbacks(behaviour_module, fake_module))

        defoverridable(unquote(behaviour_module))

        Agent.update(@agent_name, fn state ->
          Map.merge(state, unquote(initial_state))
        end)

        defp call(mfa) do
          Agent.update(@agent_name, fn state ->
            Map.put(state, mfa, true)
          end)
        end

        unquote(code)
      end

      unquote(fake_module)
    end
  end
end
