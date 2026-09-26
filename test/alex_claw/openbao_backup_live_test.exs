defmodule AlexClaw.OpenBaoBackupLiveTest do
  @moduledoc """
  AlexClaw cannot take a snapshot of its own vault: OpenBao refuses its token
  at the snapshot endpoint (0.4.0; the backup has its own credential, which
  AlexClaw never holds — openbao_backup_test.exs).
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Vault

  defp as_alexclaw(method, url) do
    %{req: req, token: token} = :sys.get_state(Vault)

    {:ok, %Req.Response{status: status}} =
      req
      |> Req.merge(method: method, url: url, headers: [{"x-vault-token", token}], retry: false)
      |> Req.request()

    status
  end

  test "the application's token cannot read a raft snapshot" do
    assert Vault.status() == :ok
    assert as_alexclaw(:get, "/v1/sys/storage/raft/snapshot") == 403
  end

  test "the application's token cannot restore one" do
    assert as_alexclaw(:post, "/v1/sys/storage/raft/snapshot-force") == 403
  end
end
