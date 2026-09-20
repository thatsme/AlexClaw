defmodule AlexClaw.Auth.ChallengeStoreTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.ChallengeStore
  alias AlexClaw.Auth.TOTP

  defp chat, do: "store_#{System.unique_integer([:positive])}"

  defp enable_2fa do
    {:ok, %{secret: secret}} = TOTP.setup()
    :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
    secret
  end

  # The table used to be created by whichever process raised the first
  # challenge, which could be a LiveView. Closing that tab took every pending
  # challenge with it.
  describe "a challenge outlives the process that created it" do
    test "created inside a task that then exits, still resolvable afterwards" do
      secret = enable_2fa()
      chat = chat()

      task = Task.async(fn -> TOTP.create_challenge(chat, %{type: :test}) end)
      _challenge_id = Task.await(task)

      refute Process.alive?(task.pid)
      assert TOTP.pending_challenge?(chat)

      assert {:ok, %{type: :test}} =
               TOTP.resolve_challenge(chat, NimbleTOTP.verification_code(secret))
    end

    test "the table survives many short-lived creators" do
      enable_2fa()
      chats = for _ <- 1..20, do: chat()

      chats
      |> Enum.map(fn c -> Task.async(fn -> TOTP.create_challenge(c, %{type: :test}) end) end)
      |> Task.await_many(5_000)

      for c <- chats, do: assert(TOTP.pending_challenge?(c))
    end
  end

  # :protected means the owner writes and everyone else reads. Without it the
  # ownership claim is a convention; with it, a stray write fails loudly.
  describe "the table is protected" do
    test "a non-owner insert raises" do
      assert_raise ArgumentError, fn ->
        :ets.insert(:totp_challenges, {"whoever", %{}})
      end
    end

    test "a non-owner delete raises" do
      assert_raise ArgumentError, fn ->
        :ets.delete(:totp_challenges, "whoever")
      end
    end

    test "a non-owner may still read" do
      enable_2fa()
      chat = chat()
      TOTP.create_challenge(chat, %{type: :test})

      assert {:ok, %{attempts: 0}} = ChallengeStore.fetch(chat)
    end
  end

  # Creating a named table is not atomic under the old whereis/new shape: two
  # concurrent first-callers both see :undefined and the loser raises.
  describe "concurrent access does not raise" do
    test "many processes creating challenges at once all succeed" do
      enable_2fa()

      results =
        1..50
        |> Enum.map(fn _ ->
          Task.async(fn -> TOTP.create_challenge(chat(), %{type: :test}) end)
        end)
        |> Task.await_many(10_000)

      assert length(results) == 50
      assert Enum.all?(results, &is_binary/1)
    end

    test "concurrent wrong codes against one challenge do not lose an increment" do
      enable_2fa()
      chat = chat()
      TOTP.create_challenge(chat, %{type: :test})

      # Three wrong codes arriving together must still end the challenge, not
      # race each other into a lost count.
      1..3
      |> Enum.map(fn i ->
        Task.async(fn -> TOTP.resolve_challenge(chat, "00000#{i}") end)
      end)
      |> Task.await_many(5_000)

      refute TOTP.pending_challenge?(chat)
    end
  end

  describe "record_attempt/2" do
    test "reports no_challenge when nothing is pending" do
      assert {:error, :no_challenge} = ChallengeStore.record_attempt(chat(), 3)
    end
  end
end
