defmodule AlexClaw.Skills.ForgeRepairTest do
  @moduledoc """
  A retry after code that failed repairs that code: the model gets the code,
  its error and the skill contract, not the knowledge-base context again. The
  full-context repair prompts ran past LM Studio's 8,192-token window on every
  retry, and each retry also re-ran the knowledge-base query rewrites.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Mox

  alias AlexClaw.Skills.CodeGenerator

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:alex_claw, :llm_impl)
    Application.put_env(:alex_claw, :llm_impl, AlexClaw.LLM.Mock)
    on_exit(fn -> restore_llm_impl(previous) end)
    :ok
  end

  defp restore_llm_impl(nil), do: Application.delete_env(:alex_claw, :llm_impl)
  defp restore_llm_impl(impl), do: Application.put_env(:alex_claw, :llm_impl, impl)

  @code "defmodule AlexClaw.Skills.Dynamic.Clock do\n  def run(_), do: :nope\nend"

  test "code that failed is sent back with its error and the contract, and nothing else" do
    test = self()

    # Only a plain completion: no fitted prompt, no embedding for a knowledge search.
    expect(AlexClaw.LLM.Mock, :complete, fn prompt, opts ->
      send(test, {:sent, prompt, opts})
      {:ok, "no code this time"}
    end)

    reason = {:load_failed, "undefined function to_iso8601_string/1"}

    assert {:error, :no_code_block, nil} =
             CodeGenerator.retry_step("a clock", "clock", "both", "auto", {reason, @code})

    assert_received {:sent, prompt, opts}
    assert prompt =~ @code
    assert prompt =~ "to_iso8601_string"
    assert opts[:system] == CodeGenerator.system_prompt()
    assert opts[:tier] == :local
    assert byte_size(prompt) < byte_size(@code) + 5_000
  end

  test "a failure that left no code is generated afresh, with the error as a hint" do
    test = self()

    expect(AlexClaw.LLM.Mock, :complete_fitted, fn build, _opts ->
      send(test, {:built, build.(:unlimited)})
      {:error, :no_available_model}
    end)

    assert {:error, {:llm_failed, :no_available_model}, nil} =
             CodeGenerator.retry_step("a clock", "clock", "none", "auto", {:no_code_block, nil})

    assert_received {:built, {:ok, prompt}}
    assert prompt =~ "```elixir"
  end

  test "a failed repair call is reported as a failed call" do
    expect(AlexClaw.LLM.Mock, :complete, fn _prompt, _opts ->
      {:error, {:prompt_too_large, [%{provider: "lm", window: 8192, prompt_tokens: 9000}]}}
    end)

    assert {:error, {:llm_failed, {:prompt_too_large, _}}, nil} =
             CodeGenerator.retry_step("a clock", "clock", "both", "LM Studio", {:x, @code})
  end
end
