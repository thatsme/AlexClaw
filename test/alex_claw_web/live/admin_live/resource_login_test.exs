defmodule AlexClawWeb.AdminLive.ResourceLoginTest do
  @moduledoc """
  Attaching a login to a recording, on the Resources page
  (reports/S4B_RECORDER.md "The resource page"; 0.4.0 S4b).

  A recording whose credential fields were recorded as slots cannot be
  played until a login is attached (recording_secrets_test.exs). On the
  page:
  - the row says which fields need a login ("login needed for #pw");
  - `attach_login` (id, selector, value) goes through `Elevation.gated` into
    `Recording.attach_login/3`: the value goes to OpenBao, bound to the
    recording's origin; the page never renders it back and no longer says a
    login is needed;
  - without the elevation it is refused, audited, and the slot stays empty.

  And one rule for every save of a recording, whichever way a value came in:
  the resource form edits metadata as raw JSON, so a password typed straight
  into a fill step must not be stored as text — `Resources.create/update`
  route fill values to OpenBao exactly like a web_automation step's inline
  recipe.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.{Repo, Resources, Secrets}
  alias AlexClaw.WebAutomation.Recording

  @url "https://portal.example.com/login"
  @password "page-login-#{System.unique_integer([:positive])}"

  setup %{conn: conn} do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, conn: authenticate(conn, sid), sid: sid}
  end

  defp elevate(sid), do: {:ok, _} = Elevation.grant(sid)

  defp recording_with_slot do
    {:ok, recipe} =
      Recording.to_recipe(@url, [
        %{"action_type" => "fill", "selector" => "#user", "value" => "alex"},
        %{"action_type" => "fill", "selector" => "#pw", "secret" => true}
      ])

    {:ok, res} =
      Resources.create_resource(%{
        name: "Portal #{System.unique_integer([:positive])}",
        type: "automation",
        url: @url,
        metadata: recipe
      })

    res
  end

  defp slots(res_id) do
    {:ok, res} = Resources.get_resource(res_id)
    Recording.login_slots(Map.take(res.metadata, ["url", "steps"]))
  end

  describe "the row" do
    test "says which fields need a login", %{conn: conn} do
      res = recording_with_slot()
      {:ok, _view, html} = live(conn, "/resources")

      assert html =~ res.name
      assert html =~ ~r/login needed/i
      assert html =~ "#pw"
    end
  end

  describe "attaching a login" do
    test "with the elevation: stored in OpenBao for the recording's origin, never rendered",
         %{conn: conn, sid: sid} do
      res = recording_with_slot()
      elevate(sid)
      {:ok, view, _html} = live(conn, "/resources")

      html =
        render_submit(view, "attach_login", %{
          "id" => to_string(res.id),
          "selector" => "#pw",
          "value" => @password
        })

      assert slots(res.id) == []
      refute html =~ @password
      refute html =~ ~r/login needed/i

      {:ok, stored} = Resources.get_resource(res.id)
      %{"secret" => name} = Enum.at(stored.metadata["steps"], 1)["value"]
      assert Secrets.get(name).binding == ["origin:https://portal.example.com"]
    end

    test "without it: refused, audited, the slot stays empty", %{conn: conn} do
      res = recording_with_slot()
      {:ok, view, _html} = live(conn, "/resources")

      render_submit(view, "attach_login", %{
        "id" => to_string(res.id),
        "selector" => "#pw",
        "value" => @password
      })

      assert slots(res.id) == ["#pw"]

      assert Repo.exists?(
               from(e in AuditEntry, where: e.decision == "deny" and like(e.reason, "%login%"))
             )
    end
  end

  describe "a password typed into the raw metadata JSON" do
    test "is stored as a reference, never as text" do
      {:ok, res} =
        Resources.create_resource(%{
          name: "Typed #{System.unique_integer([:positive])}",
          type: "automation",
          url: @url,
          metadata: %{
            "url" => @url,
            "steps" => [%{"action" => "fill", "selector" => "#pw", "value" => @password}]
          }
        })

      %{rows: [[meta]]} =
        Repo.query!("SELECT metadata::text FROM resources WHERE id = $1", [res.id])

      refute meta =~ @password
      assert meta =~ ~s("secret")
    end

    test "on an update too" do
      res = recording_with_slot()
      {:ok, current} = Resources.get_resource(res.id)

      steps =
        List.replace_at(current.metadata["steps"], 1, %{
          "action" => "fill",
          "selector" => "#pw",
          "value" => @password
        })

      {:ok, _} =
        Resources.update_resource(current, %{metadata: %{current.metadata | "steps" => steps}})

      %{rows: [[meta]]} =
        Repo.query!("SELECT metadata::text FROM resources WHERE id = $1", [res.id])

      refute meta =~ @password
    end
  end
end
