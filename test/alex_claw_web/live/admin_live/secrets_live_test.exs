defmodule AlexClawWeb.AdminLive.SecretsLiveTest do
  @moduledoc """
  The Secrets page (reports/V040_SECURITY_DESIGN.md §5; 0.4.0 S2).

  Built like the LLM providers page: a table of rows, one form, writes through
  `Elevation.gated/3` (second factor and audit). What is particular to this
  page:

  - it shows names, kinds, bindings and when each value was last set —
    NEVER a value, not even partly (the Config page's "first and last four
    characters" is exactly what this page must not do);
  - setting a value is its own action, separate from defining the secret;
    the value field is a password field, and is empty again after the form
    is submitted — the page never renders what was typed back;
  - every write needs the elevation: defining, setting a value, deleting.
    Without it the write is refused, and the refusal is audited;
  - deleting removes the catalogue row and the value in OpenBao.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.Secrets

  @value "page-secret-value-#{System.unique_integer([:positive])}"

  setup %{conn: conn} do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, conn: authenticate(conn, sid), sid: sid}
  end

  defp elevate(sid), do: {:ok, _} = Elevation.grant(sid)

  defp name, do: "page_secret_#{System.unique_integer([:positive])}"

  defp defined do
    {:ok, s} =
      Secrets.define(%{name: name(), kind: "api_token", binding: ["host:api.example.com"]})

    s
  end

  defp denied?(fragment) do
    Repo.exists?(
      from(e in AuditEntry, where: e.decision == "deny" and like(e.reason, ^"%#{fragment}%"))
    )
  end

  describe "what the page shows" do
    test "names, kinds and bindings — and never a value", %{conn: conn} do
      secret = defined()
      :ok = Secrets.put_value(secret.name, @value)

      {:ok, _view, html} = live(conn, "/secrets")

      assert html =~ secret.name
      assert html =~ "api_token"
      assert html =~ "host:api.example.com"
      refute html =~ @value
      # Not even partly: no prefix, no suffix.
      refute html =~ String.slice(@value, 0, 4) <> "…"
      refute html =~ String.slice(@value, -4, 4)
    end

    test "when a value was last set, or that it has none", %{conn: conn} do
      with_value = defined()
      without = defined()
      :ok = Secrets.put_value(with_value.name, @value)

      {:ok, _view, html} = live(conn, "/secrets")

      assert html =~ ~r/no value/i
      assert html =~ ~r/set|rotated/i
      assert html =~ without.name
    end
  end

  describe "writes need the elevation" do
    test "defining a secret without it is refused and audited", %{conn: conn} do
      n = name()
      {:ok, view, _html} = live(conn, "/secrets")

      render_submit(view, "save_secret", %{
        "secret" => %{"name" => n, "kind" => "api_token", "binding" => "host:api.example.com"}
      })

      assert is_nil(Secrets.get(n))
      assert denied?(n)
    end

    test "defining a secret with it", %{conn: conn, sid: sid} do
      elevate(sid)
      n = name()
      {:ok, view, _html} = live(conn, "/secrets")

      render_submit(view, "save_secret", %{
        "secret" => %{"name" => n, "kind" => "api_token", "binding" => "host:api.example.com"}
      })

      assert Secrets.get(n)
    end

    test "setting a value without it is refused, and nothing reaches OpenBao", %{conn: conn} do
      secret = defined()
      {:ok, view, _html} = live(conn, "/secrets")

      render_submit(view, "set_value", %{"name" => secret.name, "value" => @value})

      assert {:error, :not_found} = AlexClaw.Vault.read("alexclaw/secrets/#{secret.name}")
      assert denied?(secret.name)
    end

    test "setting a value with it: stored in OpenBao, never rendered back", %{
      conn: conn,
      sid: sid
    } do
      elevate(sid)
      secret = defined()
      {:ok, view, _html} = live(conn, "/secrets")

      html = render_submit(view, "set_value", %{"name" => secret.name, "value" => @value})

      assert {:ok, @value} = Secrets.resolve(secret.name, for: "host:api.example.com")
      refute html =~ @value, "the page rendered the value it was given"
    end

    test "the value field is a password field", %{conn: conn, sid: sid} do
      elevate(sid)
      secret = defined()
      {:ok, view, _html} = live(conn, "/secrets")

      html = render_click(view, "edit_value", %{"name" => secret.name})

      assert html =~
               ~r/<input[^>]*type="password"[^>]*name="value"|<input[^>]*name="value"[^>]*type="password"/
    end

    test "deleting without it is refused; with it, the row and the OpenBao value are gone",
         %{conn: conn, sid: sid} do
      secret = defined()
      :ok = Secrets.put_value(secret.name, @value)
      {:ok, view, _html} = live(conn, "/secrets")

      render_click(view, "delete_secret", %{"name" => secret.name})
      assert Secrets.get(secret.name), "deleted without the elevation"
      assert denied?(secret.name)

      elevate(sid)
      render_click(view, "delete_secret", %{"name" => secret.name})

      assert is_nil(Secrets.get(secret.name))
      assert {:error, :not_found} = AlexClaw.Vault.read("alexclaw/secrets/#{secret.name}")
    end
  end
end
