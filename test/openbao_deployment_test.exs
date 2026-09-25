defmodule AlexClaw.OpenBaoDeploymentTest do
  @moduledoc """
  OpenBao's deployment, as the compose files and its configuration declare it
  (reports/V040_SECURITY_DESIGN.md §1; THREAT_MODEL.md P7, P8; 0.4.0 S1).

  Checked on the files, like compose_hardening_test.exs: a property that
  holds in the file holds in every deployment made from it.

  - `openbao` runs pinned by digest, non-root, read-only root filesystem, all
    capabilities dropped, on a `vault` network that only it and AlexClaw
    join, publishing nothing to the host;
  - its data volume is mounted at /openbao/file (raft cannot write to a
    root-owned /openbao/data), with SKIP_CHOWN;
  - the unseal key is mounted read-only at /openbao/unseal, OUTSIDE the data
    volume, and nothing else mounts it;
  - `openbao-init` is a one-shot service: it writes to OpenBao's config
    volume and to AlexClaw's bootstrap mount, and AlexClaw's bootstrap mount
    is the ONLY OpenBao-related mount AlexClaw has — it never sees OpenBao's
    data, configuration or TLS key;
  - OpenBao's configuration declares the static seal from that file, raft
    storage under /openbao/file, a TLS listener, and the file audit device.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @compose "docker-compose.yml"
  @test_compose "docker-compose.test.yml"
  @config "openbao/config.hcl"

  defp services(file), do: file |> YamlElixir.read_from_file!() |> Map.fetch!("services")
  defp networks(file), do: file |> YamlElixir.read_from_file!() |> Map.get("networks", %{})

  defp mounts(service) do
    Enum.map(service["volumes"] || [], fn
      v when is_binary(v) ->
        v |> String.split(":") |> then(fn [src, dst | rest] -> {src, dst, rest} end)

      %{"source" => src, "target" => dst} = v ->
        {src, dst, if(v["read_only"], do: ["ro"], else: [])}
    end)
  end

  defp service_networks(service) do
    case service["networks"] do
      nil -> []
      list when is_list(list) -> list
      map when is_map(map) -> Map.keys(map)
    end
  end

  for file <- [@compose, @test_compose] do
    describe "#{file}" do
      setup do
        {:ok, services: services(unquote(file)), networks: networks(unquote(file))}
      end

      test "the openbao service exists, pinned by digest", %{services: s} do
        bao = Map.fetch!(s, if(unquote(file) == @compose, do: "openbao", else: "openbao-test"))

        assert bao["image"] =~ ~r/openbao.*@sha256:[0-9a-f]{64}$/,
               "image not pinned by digest: #{bao["image"]}"
      end

      test "openbao is hardened like the web automator", %{services: s} do
        bao = s[if(unquote(file) == @compose, do: "openbao", else: "openbao-test")]

        assert bao["user"] && bao["user"] not in ["0", "root", "0:0"]
        assert bao["read_only"] == true
        assert "ALL" in (bao["cap_drop"] || [])
        refute bao["privileged"]

        assert get_in(bao, ["environment", "SKIP_CHOWN"]) in ["1", 1, true] or
                 Enum.member?(List.wrap(bao["environment"]), "SKIP_CHOWN=1")
      end

      test "openbao publishes nothing to the host", %{services: s} do
        name = if(unquote(file) == @compose, do: "openbao", else: "openbao-test")
        # A service that does not exist has no ports: check it exists first.
        assert bao = s[name], "no #{name} service"
        assert (bao["ports"] || []) == []
      end

      # Production keeps OpenBao's data on a volume at /openbao/file. The test
      # stack keeps it on a tmpfs there: empty at every start, so each run
      # initialises a fresh server with nothing to clean up on the host.
      test "its data lives at /openbao/file; the unseal key is read-only, elsewhere, and only openbao mounts it",
           %{services: s} do
        name = if(unquote(file) == @compose, do: "openbao", else: "openbao-test")
        assert s[name], "no #{name} service"
        bao_mounts = mounts(s[name])
        tmpfs = List.wrap(s[name]["tmpfs"]) |> Enum.map(&(&1 |> String.split(":") |> hd()))

        assert Enum.any?(bao_mounts, fn {_src, dst, _} -> dst == "/openbao/file" end) or
                 "/openbao/file" in tmpfs,
               "no /openbao/file (volume or tmpfs)"

        assert [{unseal_src, "/openbao/unseal" <> _, opts}] =
                 Enum.filter(bao_mounts, fn {_src, dst, _} ->
                   String.starts_with?(dst, "/openbao/unseal")
                 end)

        assert "ro" in opts

        others =
          for {svc, spec} <- s,
              svc != name,
              {src, _dst, _} <- mounts(spec),
              src == unseal_src,
              do: svc

        assert others == [], "the unseal key is also mounted by #{inspect(others)}"
      end

      test "only openbao and AlexClaw (and the one-shot init) join the vault network",
           %{services: s, networks: n} do
        assert Map.has_key?(n, "vault"), "no vault network"

        members = for {svc, spec} <- s, "vault" in service_networks(spec), do: svc

        allowed =
          if unquote(file) == @compose,
            do: ["openbao", "openbao-init", "alexclaw-prod"],
            else: ["openbao-test", "openbao-test-init", "test-elixir"]

        assert Enum.sort(members) -- allowed == [],
               "unexpected on vault: #{inspect(members -- allowed)}"
      end

      test "AlexClaw sees no OpenBao data, configuration or TLS key — only its bootstrap mount",
           %{services: s} do
        app = if(unquote(file) == @compose, do: "alexclaw-prod", else: "test-elixir")
        bao = if(unquote(file) == @compose, do: "openbao", else: "openbao-test")
        # Services that do not exist have no mounts: check they exist first.
        assert s[app], "no #{app} service"
        assert s[bao], "no #{bao} service"
        assert mounts(s[bao]) != [], "#{bao} mounts nothing — the comparison would be vacuous"

        bao_sources = for {src, _dst, _} <- mounts(s[bao]), do: src
        app_sources = for {src, _dst, _} <- mounts(s[app]), do: src

        assert MapSet.disjoint?(MapSet.new(bao_sources), MapSet.new(app_sources)),
               "AlexClaw mounts something OpenBao mounts: #{inspect(Enum.filter(app_sources, &(&1 in bao_sources)))}"
      end
    end
  end

  describe "OpenBao's configuration (#{@config})" do
    setup do
      {:ok, hcl: File.read!(@config)}
    end

    test "the static seal reads its key from the read-only unseal mount", %{hcl: hcl} do
      assert hcl =~ ~r/seal\s+"static"/
      assert hcl =~ ~r|current_key\s*=\s*"file:///openbao/unseal/|
    end

    test "raft storage under /openbao/file", %{hcl: hcl} do
      assert hcl =~ ~r/storage\s+"raft"/
      assert hcl =~ ~r|path\s*=\s*"/openbao/file|
    end

    test "the listener uses TLS", %{hcl: hcl} do
      assert hcl =~ ~r/listener\s+"tcp"/
      refute hcl =~ ~r/tls_disable\s*=\s*(true|1|"true")/
      assert hcl =~ ~r/tls_cert_file/
      assert hcl =~ ~r/tls_key_file/
    end

    test "the file audit device is declared (it cannot be added through the API)", %{hcl: hcl} do
      assert hcl =~ ~r/audit\s+"file"|audit\s*\{[^}]*type\s*=\s*"file"/s
    end

    test "no removed or unsafe fields", %{hcl: hcl} do
      refute hcl =~ "disable_mlock"
      refute hcl =~ ~r/ui\s*=\s*true/
    end
  end
end
