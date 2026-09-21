defmodule AlexClawWeb.AdminLive.ControlPlanePagesTest do
  @moduledoc """
  The admin pages make their changes through ControlPlane.gated/4: the change
  and its audit row are one transaction, and what is not the database happens
  after commit.

  Flash is rendered by the layout and never reaches these assertions, so every
  claim is made against what lasts: the rows, and the cache.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation, Policy}
  alias AlexClaw.{Cluster, Repo}

  setup do
    enable_totp()
    sid = Elevation.new_sid()
    {:ok, _} = Elevation.grant(sid)
    on_exit(fn -> Elevation.revoke(sid) end)
    {:ok, sid: sid}
  end

  defp enable_totp do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
  end

  defp open(conn, sid, page) do
    {:ok, view, _html} = conn |> authenticate(sid) |> live(page)
    view
  end

  defp rows(decision, fragment) do
    Repo.all(
      from(e in AuditEntry,
        where: e.decision == ^decision and like(e.reason, ^"%#{fragment}%"),
        order_by: e.id
      )
    )
  end

  defp stored(key) do
    setting = Repo.get_by(AlexClaw.Config.Setting, key: key)
    setting && setting.value
  end

  describe "a change and its audit row" do
    test "a change the database refuses leaves no audit row behind", %{conn: conn, sid: sid} do
      view = open(conn, sid, "/policies")

      render_click(view, "create_policy", %{
        "policy" => %{"name" => "", "rule_type" => "rate_limit", "config_json" => "{}"}
      })

      refute Repo.exists?(from(p in Policy, where: p.name == ""))
      assert rows("write", "policy created: ") == []
    end

    test "a committed change has exactly one audit row", %{conn: conn, sid: sid} do
      view = open(conn, sid, "/policies")

      render_click(view, "create_policy", %{
        "policy" => %{"name" => "pages-ok", "rule_type" => "rate_limit", "config_json" => "{}"}
      })

      assert Repo.exists?(from(p in Policy, where: p.name == "pages-ok"))
      assert [_row] = rows("write", "policy created: pages-ok")
    end

    # PostgreSQL text cannot hold a NUL byte. The key goes into the audit row
    # as written (values are inspected, which escapes it), so this change's row
    # genuinely cannot be written: the change must not be made, and the loss
    # must be loud.
    test "a change whose audit row cannot be written is not made", %{conn: conn, sid: sid} do
      view = open(conn, sid, "/config")

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          render_click(view, "save", %{
            "key" => "pages.\0unrecorded",
            "value" => "anything",
            "type" => "string",
            "category" => "general"
          })
        end)

      assert log =~ "Audit row lost"

      assert Repo.aggregate(
               from(s in AlexClaw.Config.Setting, where: like(s.key, "pages.%unrecorded")),
               :count
             ) == 0

      assert Process.alive?(view.pid), "a refused change must not crash the page"
    end
  end

  describe "configuration" do
    test "is persisted in the transaction and published after it", %{conn: conn, sid: sid} do
      AlexClaw.Config.subscribe()
      view = open(conn, sid, "/config")

      render_click(view, "save", %{
        "key" => "pages.published",
        "value" => "committed",
        "type" => "string",
        "category" => "general"
      })

      assert stored("pages.published") == "committed"
      assert AlexClaw.Config.get("pages.published") == "committed"
      assert_received {:config_changed, "pages.published", "committed"}
      assert [_row] = rows("write", "pages.published")
    end

    test "enabling a gateway assigns it to this node in the same change", %{conn: conn, sid: sid} do
      view = open(conn, sid, "/config")

      render_click(view, "save", %{
        "key" => "discord.enabled",
        "value" => "true",
        "type" => "boolean",
        "category" => "discord"
      })

      assert stored("discord.node") == to_string(node())
      assert AlexClaw.Config.get("discord.node") == to_string(node())
    end

    test "a delete is removed from the database and then from the cache", %{conn: conn, sid: sid} do
      {:ok, _} = AlexClaw.Config.set("pages.deleted", "here")
      view = open(conn, sid, "/config")

      render_click(view, "delete", %{"key" => "pages.deleted"})

      assert stored("pages.deleted") == nil
      assert AlexClaw.Config.get("pages.deleted") == nil
    end
  end

  describe "memory" do
    test "deleting an entry is an audited change", %{conn: conn, sid: sid} do
      {:ok, entry} = AlexClaw.Memory.store(:fact, "pages memory probe", source: "test")
      view = open(conn, sid, "/memory")

      render_click(view, "delete", %{"id" => to_string(entry.id)})

      refute Repo.get(AlexClaw.Memory.Entry, entry.id)
      assert [_row] = rows("write", "memory entry deleted: id #{entry.id}")
    end

    test "is refused without an elevation, and the entry stays", %{conn: conn} do
      {:ok, entry} = AlexClaw.Memory.store(:fact, "pages memory kept", source: "test")
      view = open(conn, Elevation.new_sid(), "/memory")

      render_click(view, "delete", %{"id" => to_string(entry.id)})

      assert Repo.get(AlexClaw.Memory.Entry, entry.id)
      assert [_refusal] = rows("deny", "memory entry deleted: id #{entry.id}")
    end
  end

  describe "an effect outside the database" do
    # Discovery fetches the API and writes back to the resource, so asking for
    # it is audited like any change, and started only after that row commits.
    test "asking for API discovery is an audited change", %{conn: conn, sid: sid} do
      {:ok, resource} =
        AlexClaw.Resources.create_resource(%{name: "pages-discover", type: "rss_feed"},
          skip_discovery: true
        )

      view = open(conn, sid, "/resources")
      render_click(view, "discover", %{"id" => to_string(resource.id)})

      assert [_row] = rows("write", "resource discovery started: id #{resource.id}")
    end

    test "discovery for a resource that is not there leaves no row", %{conn: conn, sid: sid} do
      view = open(conn, sid, "/resources")
      render_click(view, "discover", %{"id" => "999999999"})

      assert rows("write", "resource discovery started: id 999999999") == []
    end

    test "connecting a node audits the intent, then what the node answered", %{
      conn: conn,
      sid: sid
    } do
      {:ok, node} = Cluster.create_node(%{name: "silent@nowhere.invalid", label: "probe"})
      view = open(conn, sid, "/cluster")

      render_click(view, "connect", %{"id" => to_string(node.id)})

      assert [_intent] = rows("write", "cluster node connect: id #{node.id}")
      assert [outcome] = rows("outcome", "cluster node connect: id #{node.id}")
      assert outcome.reason =~ "disconnected"
      assert Repo.get!(AlexClaw.Cluster.ClusterNode, node.id).status == "disconnected"
    end

    # Removing a node from the registry says nothing to the node, so there is
    # no effect outside the database and no outcome row: one change, one row.
    test "deleting a node is one change with one row", %{conn: conn, sid: sid} do
      {:ok, node} = Cluster.create_node(%{name: "gone@nowhere.invalid", label: "probe"})
      view = open(conn, sid, "/cluster")

      render_click(view, "delete", %{"id" => to_string(node.id)})

      refute Repo.get(AlexClaw.Cluster.ClusterNode, node.id)
      assert [_row] = rows("write", "cluster node deleted: id #{node.id}")
      assert rows("outcome", "gone@nowhere.invalid") == []
    end
  end
end
