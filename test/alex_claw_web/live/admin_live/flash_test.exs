defmodule AlexClawWeb.AdminLive.FlashTest do
  @moduledoc """
  Flash messages reach the page. Every admin page set them with `put_flash`,
  but the live session had no layout, so none was ever rendered — a web
  restore's result was shown nowhere.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows

  # Every admin page served by a LiveView, the parameter filled in. (The
  # router also mounts LiveDashboard in dev; it is not an admin page.)
  defp live_paths do
    {:ok, workflow} = Workflows.create_workflow(%{name: "flash-probe"})

    AlexClawWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&admin_live?/1)
    |> Enum.map(&String.replace(&1.path, ":id", to_string(workflow.id)))
  end

  defp admin_live?(%{plug: Phoenix.LiveView.Plug, plug_opts: view}),
    do: view |> Atom.to_string() |> String.starts_with?("Elixir.AlexClawWeb.AdminLive.")

  defp admin_live?(_route), do: false

  test "every admin page renders the flash container", %{conn: conn} do
    paths = live_paths()
    assert length(paths) >= 16

    for path <- paths do
      {:ok, view, _html} = conn |> authenticate() |> live(path)
      assert has_element?(view, "#flash-group"), "#{path} renders no flash container"
    end
  end

  test "a flash set by an event is shown", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/database")

    render_click(view, "restore", %{})

    assert view |> element("#flash-group") |> render() =~ "No file uploaded"
  end

  # The case that went unseen: the outcome of a restore answered with a code.
  test "a restore's outcome is shown on the page that asked for it", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/database")

    Phoenix.PubSub.broadcast(
      AlexClaw.PubSub,
      "database:restore",
      {:restore_finished, :error, "The restore was refused: probe"}
    )

    assert view |> element("#flash-group") |> render() =~ "The restore was refused: probe"
  end

  test "an empty flash renders no message", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/database")
    refute has_element?(view, "#flash-group > div")
  end
end
