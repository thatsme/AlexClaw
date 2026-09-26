defmodule AlexClaw.SecretsTest do
  @moduledoc """
  The secrets layer (reports/V040_SECURITY_DESIGN.md §5; THREAT_MODEL.md P1,
  P5, P8; 0.4.0 S2).

  AlexClaw keeps a CATALOGUE of secrets — name, description, kind, binding,
  dates — and never a value. The value lives in OpenBao, at
  `secret/alexclaw/secrets/<name>`. Code gets a value in exactly one way:
  `Secrets.resolve(name, for: destination)`, which

  - refuses a secret that is not bound to that destination (P5): a database
    password bound to `connection:erp` cannot be resolved for `host:evil.example`;
  - reads the value from OpenBao at that moment — nothing caches it;
  - records every attempt in the audit, allowed or refused: the secret's
    name, the destination, the outcome — never the value (P8).

  Setting a value writes OpenBao and stamps `rotated_at`; the catalogue row
  never holds it. Here the context functions are called directly; from S5
  they are reached only through the one door (with 2FA), which its own tests
  pin.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClaw.Workflows.{Executor, SkillOutcome, WorkflowRun}
  alias Ecto.Adapters.SQL.Sandbox

  @value "secret-value-#{System.unique_integer([:positive])}"

  defp name, do: "test_secret_#{System.unique_integer([:positive])}"

  defp define(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name(),
          description: "ERP database password",
          kind: "database_password",
          binding: ["connection:erp"]
        },
        overrides
      )

    {:ok, secret} = Secrets.define(attrs)
    secret
  end

  defp audited(fragment) do
    Repo.all(from(e in AuditEntry, where: like(e.reason, ^"%#{fragment}%")))
  end

  describe "the catalogue" do
    test "a secret is defined by name, description, kind and binding" do
      secret = define()
      assert secret.kind == "database_password"
      assert secret.binding == ["connection:erp"]
      assert is_nil(secret.rotated_at), "no value yet, so never rotated"
    end

    test "names are unique, lower-case identifiers" do
      secret = define()

      assert {:error, cs} =
               Secrets.define(%{
                 name: secret.name,
                 kind: "api_token",
                 binding: ["host:x.example"]
               })

      assert cs.errors[:name]

      for bad <- ["Has Upper", "with space", "a", String.duplicate("x", 65), "slash/in"] do
        assert {:error, cs} =
                 Secrets.define(%{name: bad, kind: "api_token", binding: ["host:x.example"]})

        assert cs.errors[:name], "accepted name #{inspect(bad)}"
      end
    end

    test "a secret must be bound to at least one destination, in a known form" do
      for binding <- [[], ["nowhere"], ["host:"], ["planet:mars"]] do
        assert {:error, cs} = Secrets.define(%{name: name(), kind: "api_token", binding: binding})
        assert cs.errors[:binding], "accepted binding #{inspect(binding)}"
      end

      for binding <- [
            ["host:api.github.com"],
            ["connection:erp"],
            ["origin:https://login.example.com"]
          ] do
        assert {:ok, _} = Secrets.define(%{name: name(), kind: "api_token", binding: binding})
      end
    end

    test "an unknown kind is refused" do
      assert {:error, cs} =
               Secrets.define(%{name: name(), kind: "magic", binding: ["host:x.example"]})

      assert cs.errors[:kind]
    end

    test "a value is not an attribute of the catalogue" do
      assert {:error, cs} =
               Secrets.define(%{
                 name: name(),
                 kind: "api_token",
                 binding: ["host:x.example"],
                 value: @value
               })

      assert cs.errors[:value]
    end

    test "the list shows names, kinds, bindings and dates — never a value" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)

      listed = Enum.find(Secrets.list(), &(&1.name == secret.name))
      assert listed
      refute inspect(Secrets.list()) =~ @value
    end
  end

  describe "values live in OpenBao, never in AlexClaw" do
    test "setting a value writes OpenBao and stamps rotated_at" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)

      assert {:ok, %{"value" => @value}} = AlexClaw.Vault.read("alexclaw/secrets/#{secret.name}")
      assert Secrets.get(secret.name).rotated_at
    end

    # A run writes the tables a value could leak into — the run's results,
    # the skills' outcomes, the audit log — and here the API it calls echoes
    # the credential back (S8: this test once ran no workflow at all).
    test "no table AlexClaw owns contains the value" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)
      {:ok, _} = Secrets.resolve(secret.name, for: "connection:erp")
      run_echoing_the_value()

      assert Repo.aggregate(WorkflowRun, :count) > 0
      assert Repo.aggregate(SkillOutcome, :count) > 0

      tables =
        Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
        ).rows
        |> List.flatten()

      assert length(tables) > 10, "the scan found almost no tables — it would prove nothing"

      for table <- tables do
        %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM \"#{table}\" t")
        refute Enum.any?(rows, fn [json] -> json =~ @value end), "the value is stored in #{table}"
      end
    end

    defp run_echoing_the_value do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/echo", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 200, "you sent: " <> auth)
      end)

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "scan #{System.unique_integer()}",
          enabled: true
        })

      {:ok, _step} =
        Workflows.add_step(wf, %{
          name: "Echo",
          skill: "api_request",
          config: %{
            "url" => "http://localhost:#{bypass.port}/echo",
            "headers" => %{"Authorization" => "Bearer " <> @value}
          }
        })

      {:ok, _run} = Executor.run(wf.id)
    end

    test "setting a value for a secret that is not defined is refused" do
      assert {:error, :unknown_secret} = Secrets.put_value(name(), @value)
    end

    # OpenBao's key-value store keeps old versions by default: a "rotated"
    # password would still be readable as version 1, and a deleted secret only
    # soft-deleted. For AlexClaw: one version per secret, and delete destroys
    # everything.
    test "a rotation leaves no old version behind; a delete leaves nothing" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)
      :ok = Secrets.put_value(secret.name, "rotated")

      path = "alexclaw/secrets/#{secret.name}"
      assert {:ok, %{"value" => "rotated"}} = AlexClaw.Vault.read(path)
      assert {:error, :not_found} = AlexClaw.Vault.read(path, version: 1)

      :ok = Secrets.delete(secret.name)
      assert {:error, :not_found} = AlexClaw.Vault.read(path)
      assert {:error, :not_found} = AlexClaw.Vault.read(path, version: 2)
      assert is_nil(Secrets.get(secret.name))
    end

    test "an empty value is refused" do
      secret = define()
      assert {:error, :empty_value} = Secrets.put_value(secret.name, "")
    end
  end

  describe "resolve/2 — the only way to a value" do
    test "a bound destination gets the value, read from OpenBao at that moment" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)
      assert {:ok, @value} = Secrets.resolve(secret.name, for: "connection:erp")

      # Rotated in OpenBao: the next resolve sees it. Nothing cached the old one.
      :ok = Secrets.put_value(secret.name, "rotated")
      assert {:ok, "rotated"} = Secrets.resolve(secret.name, for: "connection:erp")
    end

    test "a destination the secret is not bound to is refused, and no value is read" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)

      assert {:error, :not_bound} = Secrets.resolve(secret.name, for: "host:evil.example")
      assert {:error, :not_bound} = Secrets.resolve(secret.name, for: "connection:erp2")
    end

    test "binding is exact: no subdomain, no prefix" do
      secret = define(%{binding: ["host:api.github.com"]})
      :ok = Secrets.put_value(secret.name, @value)

      assert {:ok, _} = Secrets.resolve(secret.name, for: "host:api.github.com")
      assert {:error, :not_bound} = Secrets.resolve(secret.name, for: "host:evil.api.github.com")

      assert {:error, :not_bound} =
               Secrets.resolve(secret.name, for: "host:api.github.com.evil.example")
    end

    test "an unknown secret, and a defined one with no value yet" do
      assert {:error, :unknown_secret} = Secrets.resolve(name(), for: "connection:erp")

      secret = define()
      assert {:error, :no_value} = Secrets.resolve(secret.name, for: "connection:erp")
    end

    test "OpenBao unavailable is said, not guessed around" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)

      config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
      down = :"vault_down_#{System.unique_integer([:positive])}"

      start_supervised!(
        {AlexClaw.Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: down)}
      )

      assert {:error, :vault_unavailable} =
               Secrets.resolve(secret.name, for: "connection:erp", vault: down)
    end
  end

  describe "every attempt is audited — never the value" do
    test "an allowed resolve is recorded with name, destination and outcome" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)
      {:ok, _} = Secrets.resolve(secret.name, for: "connection:erp")

      # The resolve row, not the first row about the secret: setting the value
      # was recorded first, and it names no destination.
      entries = audited(secret.name)

      assert Enum.any?(entries, &(&1.decision == "allow" and &1.reason =~ "connection:erp")),
             "no allowed resolve row naming the destination: #{inspect(Enum.map(entries, & &1.reason))}"

      refute inspect(entries) =~ @value
    end

    test "a refused resolve is recorded as refused" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)
      {:error, :not_bound} = Secrets.resolve(secret.name, for: "host:evil.example")

      entries = audited(secret.name)
      assert Enum.any?(entries, &(&1.decision == "deny" and &1.reason =~ "host:evil.example"))
      refute inspect(entries) =~ @value
    end

    test "setting a value is recorded — never the value" do
      secret = define()
      :ok = Secrets.put_value(secret.name, @value)

      assert Enum.any?(audited(secret.name), &(&1.reason =~ ~r/set|rotat/i))
      refute inspect(audited(secret.name)) =~ @value
    end
  end
end
