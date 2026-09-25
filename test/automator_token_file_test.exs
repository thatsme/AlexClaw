defmodule AlexClaw.AutomatorTokenFileTest do
  @moduledoc """
  The web automator's shared token is a bootstrap file, generated once, not
  an environment variable an operator sets (0.4.0 S7; V040_SECURITY_DESIGN.md
  §6; reports/S7_PREMISES.md §2).

  - A one-shot service, `automator-token-init`, writes it into its own volume
    when there is none; `alexclaw-prod` and `web-automator` start only after
    it succeeded.
  - Only those two services mount the volume, read-only, and each is told
    where the file is (`WEB_AUTOMATOR_TOKEN_FILE`). No service is given
    `WEB_AUTOMATOR_TOKEN`, and the application does not read it.
  - The volume is not the OpenBao bootstrap volume: the sidecar must not see
    AlexClaw's AppRole credentials.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @volume "automator_token"

  defp compose, do: YamlElixir.read_from_file!("docker-compose.yml")
  defp service(name), do: get_in(compose(), ["services", name])

  defp mounts(service) do
    service
    |> Map.get("volumes", [])
    |> Enum.map(&mount/1)
  end

  defp mount(%{"source" => source, "target" => target} = long),
    do: {source, target, Map.get(long, "read_only", false)}

  defp mount(short) when is_binary(short) do
    case String.split(short, ":") do
      [source, target, "ro"] -> {source, target, true}
      [source, target | _] -> {source, target, false}
    end
  end

  test "a one-shot service generates the token into its own volume" do
    init = service("automator-token-init")

    assert init, "no automator-token-init service"
    assert init["restart"] == "no"
    assert Enum.any?(mounts(init), fn {source, _target, ro} -> source == @volume and not ro end)
    assert Map.has_key?(compose()["volumes"], @volume)
  end

  for name <- ["alexclaw-prod", "web-automator"] do
    test "#{name} mounts it read-only, is told where it is, and waits for it" do
      service = service(unquote(name))

      assert [{@volume, target, true}] = Enum.filter(mounts(service), &(elem(&1, 0) == @volume))
      assert service["environment"]["WEB_AUTOMATOR_TOKEN_FILE"] == Path.join(target, "token")

      assert get_in(service, ["depends_on", "automator-token-init", "condition"]) ==
               "service_completed_successfully"
    end
  end

  test "no other service mounts it" do
    mounting =
      for {name, service} <- compose()["services"],
          Enum.any?(mounts(service), &(elem(&1, 0) == @volume)),
          do: name

    assert Enum.sort(mounting) == ["alexclaw-prod", "automator-token-init", "web-automator"]
  end

  test "no service is given WEB_AUTOMATOR_TOKEN, and the application does not read it" do
    for {name, service} <- compose()["services"] do
      refute Map.has_key?(service["environment"] || %{}, "WEB_AUTOMATOR_TOKEN"),
             "#{name} is still given WEB_AUTOMATOR_TOKEN"
    end

    refute File.read!("config/runtime.exs") =~ ~s|"WEB_AUTOMATOR_TOKEN"|
    refute File.read!(".env.example") =~ ~r/^#?\s*WEB_AUTOMATOR_TOKEN=/m
  end
end
