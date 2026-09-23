defmodule AlexClaw.Skills.SkillAPIHostGuardTest do
  @moduledoc """
  F1 at the skill surface: SkillAPI.http_* goes through AlexClaw.Net.HostGuard,
  and a skill cannot pass a Req option that changes where the request goes.

  The Bypass below listens on loopback and has nothing stubbed: if any call here
  reaches it, the test fails when Bypass exits. Refusal must come before the
  request, not after a response.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    source = """
    defmodule AlexClaw.Skills.Dynamic.WebReader do
      @behaviour AlexClaw.Skill
      @impl true
      def permissions, do: [:web_read]
      @impl true
      def run(_args), do: {:ok, "reader"}
    end
    """

    File.write!(Path.join(skills_dir, "web_reader.ex"), source)
    {:ok, _} = SkillRegistry.load_skill("web_reader.ex")

    on_exit(fn ->
      SkillRegistry.unload_skill("web_reader")
      File.rm_rf!(skills_dir)
    end)

    bypass = Bypass.open()
    %{module: AlexClaw.Skills.Dynamic.WebReader, port: bypass.port}
  end

  describe "internal hosts are refused before any request" do
    test "loopback, by address and by name", %{module: mod, port: port} do
      for url <- ["http://127.0.0.1:#{port}/", "http://localhost:#{port}/"] do
        assert {:error, :blocked_host} = SkillAPI.http_get(mod, url)
        assert {:error, :blocked_host} = SkillAPI.http_post(mod, url, json: %{"a" => 1})
        assert {:error, :blocked_host} = SkillAPI.http_request(mod, :put, url)
      end
    end

    # In the test stack the name does not resolve; in production it resolves to
    # a private address. Refused either way.
    test "compose service names", %{module: mod} do
      for url <- [
            "http://web-automator:6900/play",
            "http://db-prod:5432/",
            "http://alexclaw-prod:5001/",
            "http://host.docker.internal:4000/"
          ] do
        assert {:error, :blocked_host} = SkillAPI.http_get(mod, url), url
      end
    end

    test "the cloud metadata address", %{module: mod} do
      assert {:error, :blocked_host} =
               SkillAPI.http_get(mod, "http://169.254.169.254/latest/meta-data/")
    end
  end

  # Options are an allow-list, checked before the host: every URL here is
  # internal, so an implementation that checks the host first answers
  # :blocked_host and fails. These are the options that replace or reconfigure
  # the transport — the guard lives in the adapter, so they would bypass it.
  describe "options that touch the transport are refused" do
    for {name, opt} <- [
          unix_socket: [unix_socket: "/var/run/docker.sock"],
          base_url: [base_url: "http://127.0.0.1"],
          connect_options: [connect_options: [hostname: "localhost"]],
          plug: [plug: {Req.Test, __MODULE__}],
          adapter: [adapter: :custom],
          finch: [finch: SomeOtherFinch],
          finch_request: [finch_request: :custom]
        ] do
      test "#{name}", %{module: mod, port: port} do
        assert {:error, :option_not_allowed} =
                 SkillAPI.http_get(mod, "http://127.0.0.1:#{port}/", unquote(Macro.escape(opt)))
      end
    end
  end

  # Redirects and retries are safe once the guard is the adapter: every hop and
  # every retry goes through it. Production skills pass these today
  # (hexdocs_guides_scraper: retry: false; web_browse_v2: redirect, max_redirects).
  # Accepted means the option check passes and the host check still refuses.
  describe "options that only shape the request are accepted" do
    for opts <- [
          [retry: false],
          [retry: :transient, max_retries: 2],
          [redirect: true, max_redirects: 5],
          [receive_timeout: 5_000],
          [headers: [{"accept", "text/html"}], params: [q: "x"]]
        ] do
      test "#{inspect(opts)}", %{module: mod, port: port} do
        assert {:error, :blocked_host} =
                 SkillAPI.http_get(mod, "http://127.0.0.1:#{port}/", unquote(Macro.escape(opts)))
      end
    end
  end

  test "a skill without :web_read is still refused on permission first" do
    assert {:error, :permission_denied} =
             SkillAPI.http_get(FakeModule, "http://127.0.0.1/")
  end
end
