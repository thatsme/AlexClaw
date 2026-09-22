defmodule AlexClaw.LLM.OneLocalProviderTest do
  @moduledoc """
  One local provider is enabled at a time, and one local call runs at a time.

  Every local provider is a model server on this host. Two of them, each
  holding a model, is 16 GB of a 24 GB machine: on 2026-09-22 LM Studio and
  Ollama together left 20 MB free and the host had to be powered off.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM
  alias AlexClaw.LLM.{LocalLock, ProviderSeeder}

  defp local(name, attrs \\ %{}) do
    LLM.create_provider(
      Map.merge(
        %{name: name, type: "ollama", tier: "local", model: "m", host: "http://h", enabled: true},
        attrs
      )
    )
  end

  defp errors(changeset), do: Enum.map_join(changeset.errors, " ", fn {_f, {msg, _}} -> msg end)

  describe "enabling a local provider" do
    test "the first is allowed; a second is refused, and says which one holds the place" do
      assert {:ok, first} = local("LM Studio")
      assert {:error, changeset} = local("Ollama")

      assert errors(changeset) =~ "LM Studio"
      assert errors(changeset) =~ "only one"
      assert LLM.enabled_local().id == first.id
    end

    test "a second is allowed once the first is disabled" do
      {:ok, first} = local("LM Studio")
      {:error, _} = local("Ollama")

      assert {:ok, _} = LLM.update_provider(first, %{enabled: false})
      assert {:ok, second} = local("Ollama")
      assert LLM.enabled_local().id == second.id
    end

    test "a disabled local provider may be created while another is enabled" do
      {:ok, _} = local("LM Studio")
      assert {:ok, _} = local("Ollama", %{enabled: false})
    end

    test "enabling one that is already the enabled local provider is not refused" do
      {:ok, provider} = local("LM Studio")
      assert {:ok, _} = LLM.update_provider(provider, %{priority: 5, enabled: true})
    end

    test "providers outside the local tier are not limited" do
      {:ok, _} = local("LM Studio")

      for name <- ["Gemini Flash", "Claude Haiku"] do
        assert {:ok, _} =
                 LLM.create_provider(%{
                   name: name,
                   type: "gemini",
                   tier: "light",
                   model: "m",
                   enabled: true
                 })
      end
    end

    test "with none enabled, there is no enabled local provider" do
      {:ok, _} = local("LM Studio", %{enabled: false})
      assert LLM.enabled_local() == nil
    end
  end

  describe "the seeder" do
    test "enables at most one local provider, whatever the settings ask for" do
      for key <- ~w(llm.ollama_enabled llm.lmstudio_enabled) do
        AlexClaw.Config.set(key, "true", type: "boolean", category: "llm")
      end

      AlexClaw.Config.set("llm.ollama_host", "http://ollama:11434",
        type: "string",
        category: "llm"
      )

      AlexClaw.Config.set("llm.lmstudio_host", "http://lmstudio:1234",
        type: "string",
        category: "llm"
      )

      ProviderSeeder.seed()

      enabled = Enum.filter(LLM.list_providers(), &(&1.tier == "local" and &1.enabled))
      assert length(enabled) == 1
      assert Enum.count(LLM.list_providers(), &(&1.tier == "local")) >= 2
    end
  end

  describe "the local-call lock" do
    test "a second local call is refused while one is in flight" do
      test = self()

      holder =
        spawn(fn ->
          send(test, {:acquired, LocalLock.acquire()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:acquired, :ok}
      assert LocalLock.acquire() == {:error, :local_model_busy}

      send(holder, :stop)
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert LocalLock.acquire() == :ok
      LocalLock.release()
    end

    test "run/1 releases the lock after its function returns" do
      assert LocalLock.run(fn -> :answered end) == :answered
      assert LocalLock.acquire() == :ok
      LocalLock.release()
    end

    test "a call refused by the lock reads as words" do
      assert AlexClaw.FailureText.describe(:local_model_busy) =~ "already running"
    end
  end
end
