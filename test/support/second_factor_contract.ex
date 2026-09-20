defmodule AlexClaw.SecondFactorContract do
  @moduledoc """
  The contract every `AlexClaw.Auth.SecondFactor` implementation must keep.

  A behaviour is a list of function names until something checks what the
  functions must *do*. These are the promises the rest of the system relies on
  — the limits, the audit rows and the elevation window are all built on "a
  presented secret either held or did not" — so a second implementation that
  passed the compiler and failed these would break them all silently.

  Use it from a test module:

      defmodule MyFactorTest do
        use AlexClaw.SecondFactorContract,
          impl: MyFactor,
          setup: &MyFactorTest.configure/0
      end

  `setup` returns a map with `:valid` (a secret that must be accepted) and
  optionally `:web_only` (a secret accepted in the browser and refused over a
  gateway). It runs before each test.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use AlexClaw.DataCase, async: false

      @moduletag :integration

      @impl_module Keyword.fetch!(opts, :impl)
      @configure Keyword.fetch!(opts, :setup)

      setup do
        {:ok, secrets: @configure.()}
      end

      describe "the behaviour is implemented" do
        test "every callback is exported" do
          Code.ensure_loaded!(@impl_module)

          for {name, arity} <- [verify: 2, configured?: 0, name: 0] do
            assert function_exported?(@impl_module, name, arity),
                   "#{inspect(@impl_module)} does not export #{name}/#{arity}"
          end
        end

        test "it declares the behaviour, so a missing callback is a warning" do
          behaviours =
            @impl_module.module_info(:attributes)
            |> Keyword.get_values(:behaviour)
            |> List.flatten()

          assert AlexClaw.Auth.SecondFactor in behaviours
        end

        test "name/0 is a short atom, for logs and the UI" do
          assert is_atom(@impl_module.name())
          refute @impl_module.name() == nil
        end
      end

      describe "configured?/0" do
        test "is true once the factor is set up", %{secrets: _secrets} do
          assert @impl_module.configured?(),
                 "the setup function left the factor unconfigured, so nothing below is meaningful"
        end
      end

      describe "verify/2" do
        test "accepts a valid secret and says which factor it was", %{secrets: secrets} do
          assert {:ok, factor} = @impl_module.verify(secrets.valid, :web)
          assert is_atom(factor)
        end

        test "refuses a wrong secret", %{secrets: _secrets} do
          assert {:error, :invalid_code} = @impl_module.verify("000000", :web)
        end

        # Callers pass whatever the operator typed. An implementation that
        # raises here would turn a typo into a crashed LiveView.
        test "refuses an empty secret rather than raising", %{secrets: _secrets} do
          assert {:error, :invalid_code} = @impl_module.verify("", :web)
        end

        test "refuses a secret of the wrong shape rather than raising", %{secrets: _secrets} do
          assert {:error, :invalid_code} = @impl_module.verify("not-a-code-at-all", :web)
        end

        test "refuses a very long secret rather than raising", %{secrets: _secrets} do
          assert {:error, :invalid_code} = @impl_module.verify(String.duplicate("9", 500), :web)
        end

        # The whole point of a second factor: the same secret twice is one use.
        test "does not accept the same secret twice", %{secrets: secrets} do
          assert {:ok, _factor} = @impl_module.verify(secrets.valid, :web)
          assert {:error, :invalid_code} = @impl_module.verify(secrets.valid, :web)
        end

        test "answers on the gateway route as well", %{secrets: secrets} do
          assert {:ok, _factor} = @impl_module.verify(secrets.valid, :gateway)
        end
      end

      describe "a secret the implementation restricts to the browser" do
        test "is accepted there and refused over a gateway", %{secrets: secrets} do
          web_only(Map.get(secrets, :web_only), @impl_module)
        end
      end

      # An implementation without a browser-only secret skips this, rather than
      # the contract pretending every factor has one.
      defp web_only(nil, _module), do: assert(true)

      defp web_only(secret, module) do
        assert {:error, :invalid_code} = module.verify(secret, :gateway)
        assert {:ok, _factor} = module.verify(secret, :web)
      end
    end
  end
end
