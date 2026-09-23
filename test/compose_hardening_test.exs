defmodule AlexClaw.ComposeHardeningTest do
  @moduledoc """
  Web automator, phase 2 (reports/WEB_AUTOMATOR_TARGET.md §1.1; backlog
  "database reachable by IP from the sidecar").

  **The database accepts only the app's network.** On OrbStack, a separate
  Docker network hides the database's name but still carries traffic to its
  IP (0.3.43 deploy, check 7). So the restriction moves into Postgres itself,
  which enforces it whatever the engine does.

  A subnet-wide rule is not enough: on OrbStack a connection from another
  network reaches Postgres rewritten to an address **inside the default
  subnet** — the gateway in the phase-2 dry run, `10.213.61.128` (the first
  address of the automatic range) in the 0.3.44 deploy. Which address the
  engine picks is its business, not ours. So Postgres admits only the exact
  addresses of the services that need it, and those addresses are chosen
  where no engine rewrite can land: outside the automatic `ip_range`, and not
  the gateway.

  - both networks declare a fixed subnet, and the subnets do not overlap;
  - the default network limits automatic addresses with an `ip_range`;
  - alexclaw-prod and migrate have a pinned `ipv4_address` on the default
    network — inside its subnet, outside its `ip_range`, never its gateway;
  - db-prod runs with a mounted pg_hba.conf (`-c hba_file=…`);
  - every `host` line in it is one of those pinned addresses as a /32, with
    scram-sha-256 — never a subnet, `all`, `samenet`, `trust` or `md5`; and
    each pinned address has its line, so the app can connect. `local` lines
    (the container's own socket) may stay as they are.

  **The sidecar runs with as little as possible:** not root, every capability
  dropped, no privilege escalation, a read-only root filesystem with a tmpfs
  `/tmp`. The Python test service runs under the same constraints, so the
  sidecar's suite — the real-Chromium tests included — proves the browser
  works as the production container will run it.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  import Bitwise

  @compose "docker-compose.yml"

  @db_clients ~w(alexclaw-prod migrate)

  defp compose(file \\ @compose), do: YamlElixir.read_from_file!(file)
  defp service(doc, name), do: doc |> Map.fetch!("services") |> Map.fetch!(name)

  defp subnet(doc, network) do
    doc
    |> get_in(["networks", network, "ipam", "config"])
    |> List.wrap()
    |> Enum.find_value(& &1["subnet"])
  end

  defp parse_cidr(cidr) do
    [addr, bits] = String.split(cidr, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(addr))
    {(a <<< 24) + (b <<< 16) + (c <<< 8) + d, String.to_integer(bits)}
  end

  defp overlap?(cidr1, cidr2) do
    {a1, b1} = parse_cidr(cidr1)
    {a2, b2} = parse_cidr(cidr2)
    bits = min(b1, b2)
    (a1 &&& mask(bits)) == (a2 &&& mask(bits))
  end

  defp mask(bits), do: bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF

  defp inside?(ip, cidr) do
    {net, bits} = parse_cidr(cidr)
    {addr, 32} = parse_cidr(ip <> "/32")
    (addr &&& mask(bits)) == (net &&& mask(bits))
  end

  # Docker's default gateway is the subnet's first address unless ipam says otherwise.
  defp gateway(doc, network) do
    config = doc |> get_in(["networks", network, "ipam", "config"]) |> List.wrap() |> hd()

    config["gateway"] || first_address(config["subnet"])
  end

  defp first_address(cidr) do
    {net, _bits} = parse_cidr(cidr)
    <<a, b, c, d>> = <<net + 1::32>>
    Enum.join([a, b, c, d], ".")
  end

  defp pinned_address(doc, name) do
    get_in(service(doc, name), ["networks", "default", "ipv4_address"])
  end

  defp ip_range(doc, network) do
    doc
    |> get_in(["networks", network, "ipam", "config"])
    |> List.wrap()
    |> Enum.find_value(& &1["ip_range"])
  end

  defp first_ip(cidr), do: cidr |> String.split("/") |> hd()

  # "./path:/target[:ro]" → {"./path", "/target"}
  defp mount(volume) when is_binary(volume) do
    [source, target | _] = String.split(volume, ":")
    {source, target}
  end

  defp mount(%{"source" => source, "target" => target}), do: {source, target}

  defp hba_mount(db) do
    Enum.find_value(db["volumes"] || [], fn volume ->
      {source, target} = mount(volume)
      if String.ends_with?(target, "pg_hba.conf"), do: {source, target}
    end)
  end

  defp hba_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split/1)
  end

  describe "the database accepts only the app's network" do
    test "default and automation declare fixed, non-overlapping subnets" do
      doc = compose()
      default = subnet(doc, "default")
      automation = subnet(doc, "automation")

      assert is_binary(default), "networks.default has no ipam subnet"
      assert is_binary(automation), "networks.automation has no ipam subnet"
      refute overlap?(default, automation), "#{default} overlaps #{automation}"
    end

    test "db-prod runs with a mounted pg_hba.conf" do
      db = service(compose(), "db-prod")

      mount = hba_mount(db)
      assert mount, "db-prod mounts no pg_hba.conf"
      {source, target} = mount
      assert File.exists?(source), "#{source} is not in the repository"

      command = db["command"] |> List.wrap() |> Enum.join(" ")
      assert command =~ "hba_file=#{target}", "db-prod does not start with hba_file=#{target}"
    end

    test "the database's clients have pinned addresses inside the subnet, outside the automatic range, not the gateway" do
      doc = compose()
      default = subnet(doc, "default")
      gateway = gateway(doc, "default")
      ip_range = ip_range(doc, "default")

      assert is_binary(ip_range),
             "networks.default has no ip_range: automatic addresses (and engine rewrites) may land on a pinned client"

      assert inside?(first_ip(ip_range), default), "ip_range #{ip_range} is outside #{default}"

      for name <- @db_clients do
        address = pinned_address(doc, name)
        assert is_binary(address), "#{name} has no pinned ipv4_address on the default network"
        assert inside?(address, default), "#{name}'s #{address} is outside #{default}"

        refute inside?(address, ip_range),
               "#{name}'s #{address} is inside the automatic range #{ip_range}"

        refute address == gateway, "#{name} is pinned to the gateway #{gateway}"
      end
    end

    test "pg_hba.conf admits exactly the pinned client addresses, with scram-sha-256" do
      doc = compose()
      allowed = MapSet.new(@db_clients, &(pinned_address(doc, &1) <> "/32"))
      mount = hba_mount(service(doc, "db-prod"))
      assert mount, "db-prod mounts no pg_hba.conf"
      {source, _target} = mount

      host_lines = for [type | _] = line <- hba_lines(source), type != "local", do: line

      for [type, _db, _user, address, method | _] = line <- host_lines do
        assert type in ["host", "hostssl"], "unexpected line: #{Enum.join(line, " ")}"
        assert address in allowed, "#{address} is not a pinned client address (/32)"
        assert method == "scram-sha-256", "#{address} uses #{method}"
      end

      admitted = MapSet.new(host_lines, &Enum.at(&1, 3))

      for address <- allowed do
        assert address in admitted,
               "#{address} has no pg_hba.conf line: that client cannot connect"
      end
    end

    test "the app is on the default network, the sidecar is not" do
      doc = compose()
      app = service(doc, "alexclaw-prod")["networks"]
      sidecar = service(doc, "web-automator")["networks"]

      networks = fn n -> if is_map(n), do: Map.keys(n), else: List.wrap(n) end
      assert "default" in networks.(app)
      refute "default" in networks.(sidecar)
    end
  end

  describe "the sidecar runs with as little as possible" do
    for {file, name} <- [
          {"docker-compose.yml", "web-automator"},
          {"docker-compose.test.yml", "test-python"}
        ] do
      test "#{file}: #{name} is not root" do
        user = to_string(service(compose(unquote(file)), unquote(name))["user"] || "")
        refute user in ["", "0", "root", "0:0", "root:root"], "#{unquote(name)} runs as root"
      end

      test "#{file}: #{name} drops every capability and cannot escalate" do
        svc = service(compose(unquote(file)), unquote(name))
        assert "ALL" in List.wrap(svc["cap_drop"]), "#{unquote(name)} keeps capabilities"

        assert "no-new-privileges:true" in List.wrap(svc["security_opt"]),
               "#{unquote(name)} can gain privileges"
      end

      test "#{file}: #{name} has a read-only root and a tmpfs /tmp" do
        svc = service(compose(unquote(file)), unquote(name))
        assert svc["read_only"] == true, "#{unquote(name)} root filesystem is writable"

        tmpfs =
          svc["tmpfs"]
          |> List.wrap()
          |> Enum.map(&(&1 |> to_string() |> String.split(":") |> hd()))

        assert "/tmp" in tmpfs, "#{unquote(name)} has no tmpfs /tmp"
      end
    end
  end
end
