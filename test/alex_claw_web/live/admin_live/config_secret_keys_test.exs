defmodule AlexClawWeb.AdminLive.ConfigSecretKeysTest do
  @moduledoc """
  Secret settings on the Config page (reports/V040_SECURITY_DESIGN.md §5;
  THREAT_MODEL.md P1, P2; 0.4.0 S3).

  The user configures Telegram on the Config page as always; the page is
  what changes underneath:
  - a secret key shows "set on <date>" or "not set" — never the value and
    never part of it (the old placeholder showed its first and last four
    characters);
  - saving a new value needs the elevation, goes through `persist/3` and so
    to OpenBao, and the page never renders it back; the audit row names the
    key, never the value;
  - saving it empty keeps the current value;
  - Clear needs the elevation and removes the value from OpenBao
    (`Config.clear/1`);
  - without the elevation, both are refused, audited, and nothing changes.

  Event names and params are the page's own (reported 2026-09-25): `save`
  with key, value, type, description, category, and `_clear` for Clear.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.Config

  @token "777-page-token-#{System.unique_integer([:positive])}"
  @key "telegram.bot_token"

  setup %{conn: conn} do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, conn: authenticate(conn, sid), sid: sid}
  end

  defp elevate(sid), do: {:ok, _} = Elevation.grant(sid)

  defp save(view, value, extra \\ %{}) do
    render_submit(
      view,
      "save",
      Map.merge(
        %{
          "key" => @key,
          "value" => value,
          "type" => "string",
          "description" => "",
          "category" => "telegram"
        },
        extra
      )
    )
  end

  defp current, do: Config.secret(@key, for: Config.secret_binding(@key))

  defp audit_rows do
    Repo.all(from(e in AuditEntry, where: like(e.reason, ^"%#{@key}%")))
  end

  describe "what the page shows for a secret key" do
    test "set: the date, never the value or any part of it", %{conn: conn} do
      {:ok, _} = Config.set(@key, @token, type: "string", category: "telegram")

      {:ok, _view, html} = live(conn, "/config")

      assert html =~ ~r/set on/i
      refute html =~ @token
      refute html =~ String.slice(@token, 0, 4)
      refute html =~ String.slice(@token, -4, 4)
    end

    test "not set: says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/config")
      assert html =~ ~r/not set/i
    end
  end

  describe "saving" do
    test "with the elevation: stored in OpenBao, never rendered back, audited without the value",
         %{conn: conn, sid: sid} do
      elevate(sid)
      {:ok, view, _html} = live(conn, "/config")

      html = save(view, @token)

      assert {:ok, @token} = current()
      refute html =~ @token
      assert audit_rows() != []
      refute inspect(audit_rows()) =~ @token
    end

    test "without it: refused, audited, nothing stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/config")

      save(view, @token)

      assert {:error, _} = current()
      assert Enum.any?(audit_rows(), &(&1.decision == "deny"))
      refute inspect(audit_rows()) =~ @token
    end

    test "empty keeps the current value", %{conn: conn, sid: sid} do
      {:ok, _} = Config.set(@key, @token, type: "string", category: "telegram")
      elevate(sid)
      {:ok, view, _html} = live(conn, "/config")

      save(view, "")

      assert {:ok, @token} = current()
    end
  end

  describe "clearing" do
    test "with the elevation: removed from OpenBao, the page says not set", %{
      conn: conn,
      sid: sid
    } do
      {:ok, _} = Config.set(@key, @token, type: "string", category: "telegram")
      elevate(sid)
      {:ok, view, _html} = live(conn, "/config")

      html = save(view, "", %{"_clear" => "true"})

      assert {:error, reason} = current()
      assert reason in [:unknown_secret, :no_value]
      assert html =~ ~r/not set/i
    end

    test "without it: refused, the value stays", %{conn: conn} do
      {:ok, _} = Config.set(@key, @token, type: "string", category: "telegram")
      {:ok, view, _html} = live(conn, "/config")

      save(view, "", %{"_clear" => "true"})

      assert {:ok, @token} = current()
      assert Enum.any?(audit_rows(), &(&1.decision == "deny"))
    end
  end
end
