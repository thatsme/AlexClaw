defmodule AlexClaw.OpenBaoBackupTest do
  @moduledoc """
  OpenBao is backed up with its own snapshot, by a credential that can do
  nothing else, and that AlexClaw never holds (0.4.0 release blocker: every
  secret lives in OpenBao).

  - `openbao/init.sh` writes a `backup` policy that grants one thing: reading
    a raft snapshot (`sys/storage/raft/snapshot`). AlexClaw's policy grants
    nothing under `sys/storage`.
  - A `backup` AppRole with that policy only (no default policy), bound to the
    backup service's own address, short-lived tokens. Its role_id and
    secret_id go to their own volume, never to AlexClaw's bootstrap mount.
  - `openbao-backup` is a one-shot service in the `backup` profile: `docker
    compose up` never starts it. It is the only service besides
    `openbao-init` that mounts the backup credentials, read-only; AlexClaw
    does not.
  - `scripts/backup-openbao.sh` saves the snapshot next to the database
    backups, mode 600, and checks it before saying it is done.

  Checked on the files, like openbao_deployment_test.exs. That AlexClaw's own
  token cannot take a snapshot is checked against OpenBao in
  openbao_backup_live_test.exs.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @init File.read!("openbao/init.sh")
  @compose "docker-compose.yml"
  @script "scripts/backup-openbao.sh"

  defp policy(name) do
    [_, body] =
      Regex.run(~r/bao policy write #{name} - [^\n]*<<'POLICY'\n(.*?)\nPOLICY/s, @init)

    body
  end

  defp paths(policy_text),
    do: ~r/path "([^"]+)"/ |> Regex.scan(policy_text, capture: :all_but_first) |> List.flatten()

  defp services, do: @compose |> YamlElixir.read_from_file!() |> Map.fetch!("services")

  defp sources(service) do
    Enum.map(service["volumes"] || [], fn
      v when is_binary(v) -> v |> String.split(":") |> hd()
      %{"source" => src} -> src
    end)
  end

  describe "the backup policy" do
    test "grants reading a raft snapshot, and nothing else" do
      backup = policy("backup")
      assert paths(backup) == ["sys/storage/raft/snapshot"]
      assert backup =~ ~r/capabilities = \["read"\]/
    end

    test "AlexClaw's policy grants nothing under sys/storage" do
      refute Enum.any?(paths(policy("alexclaw")), &String.starts_with?(&1, "sys/"))
    end
  end

  describe "the backup AppRole" do
    setup do
      [_, role] =
        Regex.run(~r/bao write auth\/approle\/role\/backup \\\n((?:[^\n]*\\\n)*[^\n]*)/, @init)

      %{role: role}
    end

    test "has the backup policy only", %{role: role} do
      assert role =~ "token_policies=backup"
      assert role =~ "token_no_default_policy=true"
    end

    test "is bound to the backup service's address", %{role: role} do
      assert role =~ ~s(secret_id_bound_cidrs="$BACKUP_ADDRESS/32")
      assert role =~ ~s(token_bound_cidrs="$BACKUP_ADDRESS/32")
    end

    test "has short-lived, single-use tokens", %{role: role} do
      assert [_, ttl] = Regex.run(~r/token_ttl=(\d+)m/, role)
      assert String.to_integer(ttl) <= 15
      # The snapshot read uses it up: the token cannot revoke itself (no
      # default policy), and needs no other path to.
      assert role =~ "token_num_uses=1"
    end

    test "its credentials are written to the backup volume, not the bootstrap mount" do
      assert @init =~ ~s("$BACKUP_CREDENTIALS/role_id")
      assert @init =~ ~s("$BACKUP_CREDENTIALS/secret_id")
      refute @init =~ ~r/role\/backup\/secret-id[^\n]*\n[^\n]*\$BOOTSTRAP/
    end
  end

  describe "#{@compose}" do
    test "openbao-backup runs only on demand, in the backup profile" do
      backup = Map.fetch!(services(), "openbao-backup")
      assert backup["profiles"] == ["backup"]
      assert backup["restart"] == "no"
    end

    test "openbao-backup is hardened like openbao-init" do
      backup = services()["openbao-backup"]
      assert backup["read_only"] == true
      assert "ALL" in (backup["cap_drop"] || [])
      assert "no-new-privileges:true" in (backup["security_opt"] || [])
      assert (backup["ports"] || []) == []
    end

    test "only openbao-init and openbao-backup mount the backup credentials; AlexClaw never does" do
      mounting =
        for {name, spec} <- services(), "openbao_backup" in sources(spec), do: name

      assert Enum.sort(mounting) == ["openbao-backup", "openbao-init"]

      assert Enum.any?(services()["openbao-backup"]["volumes"], fn v ->
               is_binary(v) and String.starts_with?(v, "openbao_backup:") and
                 String.ends_with?(v, ":ro")
             end),
             "openbao-backup must mount the credentials read-only"
    end

    # BACKUP_DIR is the db_backup skill's directory, which AlexClaw mounts: the
    # snapshots go somewhere AlexClaw never sees.
    test "openbao-backup writes where AlexClaw mounts nothing" do
      [backups] =
        for %{"target" => "/backups", "source" => src} <- services()["openbao-backup"]["volumes"],
            do: src

      assert backups =~ "OPENBAO_BACKUP_DIR"
      refute backups =~ ~r/\$\{BACKUP_DIR/
      refute backups in sources(services()["alexclaw-prod"])
    end

    # A restore stages the snapshot in /tmp; the root filesystem is read-only.
    test "openbao has a writable /tmp, so a snapshot can be restored" do
      tmpfs =
        services()["openbao"]["tmpfs"]
        |> List.wrap()
        |> Enum.map(&(&1 |> String.split(":") |> hd()))

      assert "/tmp" in tmpfs
    end

    test "openbao-backup never sees OpenBao's data, TLS key or unseal key" do
      assert backup = services()["openbao-backup"], "no openbao-backup service"
      backup_sources = sources(backup)
      assert backup_sources != [], "openbao-backup mounts nothing — the check would be vacuous"

      for forbidden <- ["openbao_data", "openbao_tls", "openbao_bootstrap"] do
        refute forbidden in backup_sources, "openbao-backup mounts #{forbidden}"
      end

      refute Enum.any?(backup_sources, &String.contains?(&1, "OPENBAO_UNSEAL_DIR"))
    end
  end

  describe "#{@script}" do
    setup do
      %{script: File.read!(@script)}
    end

    test "writes next to the database backups, named like them", %{script: script} do
      assert script =~ "backups"
      assert script =~ ~r/openbao-\$\{?stamp\}?-\$\{?reason\}?\.snap/
    end

    test "refuses to write into the directory AlexClaw mounts", %{script: script} do
      assert script =~ "OPENBAO_BACKUP_DIR"
      assert script =~ ~r/BACKUP_DIR.*refus|refus.*BACKUP_DIR/s
    end

    test "leaves the snapshot readable by its owner only", %{script: script} do
      assert script =~ "chmod 600"
    end

    test "checks the snapshot before reporting it done", %{script: script} do
      assert script =~ "snapshot inspect" or script =~ "size"
    end
  end
end
