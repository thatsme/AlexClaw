defmodule AlexClaw.Workflows.UnmovedCredentialsTest do
  @moduledoc """
  A credential still held as a value — one 0.3.x left that the upgrade has
  not moved yet (OpenBao was down at boot) — is refused at run time, never
  handed to the skill (0.4.0 S7).

  Before S7 such a value was decrypted on the way out of the database and
  used. Now nothing decrypts outside the boot upgrade: the value would reach
  the skill as 0.3.x ciphertext, or, for a resource, as plaintext that never
  went through OpenBao's binding. Either way the run stops, saying why.
  """
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Resources.ResourceSecrets
  alias AlexClaw.Workflows.StepSecrets
  alias AlexClawTest.Legacy

  test "a step's declared credential that is still a value is refused" do
    config = %{"bot_token" => Legacy.seal("123:legacy"), "chat_id" => "1"}

    assert {:error, {:secret, "bot_token", :not_moved}} =
             StepSecrets.resolved("telegram_notify", config)
  end

  test "a resource's credential that is still a value is refused" do
    resource = %{
      name: "legacy api",
      url: "https://api.example.com",
      metadata: %{"auth" => %{"type" => "bearer", "value" => "tok-plain"}}
    }

    assert {:error, {:secret, "resource legacy api", :not_moved}} =
             ResourceSecrets.resolved(resource)
  end

  test "a step with no credential value is untouched" do
    assert {:ok, %{"chat_id" => "1"}} =
             StepSecrets.resolved("telegram_notify", %{"chat_id" => "1"})
  end
end
