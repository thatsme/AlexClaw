defmodule AlexClaw.LLM.ProviderCredentialsTest do
  @moduledoc """
  An LLM provider's API key and header values are kept in OpenBao, as secrets
  the provider owns, bound to the host its calls go to; the row keeps
  references (0.4.0 S7; V040_SECURITY_DESIGN.md §6; reports/S7_PREMISES.md §1).

  - A header's name stays readable, its value is a reference: the form cannot
    tell a credential header from any other.
  - A key with no host to bind to is refused at save.
  - Leaving the key blank on an edit keeps it; moving the provider to another
    host with the key kept is refused — the key must be entered again.
  - A call resolves the key for the provider's host each time.
  - Deleting the provider deletes its secrets.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{LLM, Secrets}
  alias AlexClaw.LLM.{Client, Provider}

  defp attrs(overrides) do
    Map.merge(
      %{
        name: "remote-#{System.unique_integer([:positive])}",
        type: "openai_compatible",
        tier: "light",
        model: "m",
        enabled: false
      },
      overrides
    )
  end

  defp raw_row(id) do
    %{rows: [[text]]} =
      Repo.query!("SELECT row_to_json(p)::text FROM llm_providers p WHERE id = $1", [id])

    text
  end

  defp names(%{credentials: credentials}) do
    [
      get_in(credentials, ["api_key", "secret"])
      | Enum.map(Map.get(credentials, "headers", %{}), fn {_h, ref} -> ref["secret"] end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  test "the key and header values go to OpenBao, bound to the host; the row holds none" do
    assert {:ok, provider} =
             LLM.create_provider(
               attrs(%{
                 host: "https://llm.example.com",
                 api_key: "sk-new-1",
                 headers: %{"X-Org" => "org-1"}
               })
             )

    row = raw_row(provider.id)
    refute row =~ "sk-new-1"
    refute row =~ "org-1"
    assert row =~ "X-Org"

    assert %{
             "api_key" => %{"secret" => key_name},
             "headers" => %{"X-Org" => %{"secret" => header_name}}
           } =
             provider.credentials

    assert {:ok, "sk-new-1"} = Secrets.resolve(key_name, for: "host:llm.example.com")
    assert {:ok, "org-1"} = Secrets.resolve(header_name, for: "host:llm.example.com")
    assert {:error, _} = Secrets.resolve(key_name, for: "host:elsewhere.example.com")
  end

  test "a gemini key is bound to Google's API host" do
    assert {:ok, provider} = LLM.create_provider(attrs(%{type: "gemini", api_key: "AIza-new"}))
    %{"api_key" => %{"secret" => name}} = provider.credentials

    assert {:ok, "AIza-new"} =
             Secrets.resolve(name, for: "host:generativelanguage.googleapis.com")
  end

  test "a key with no host to bind to is refused" do
    new = attrs(%{api_key: "sk-nowhere"})

    assert {:error, changeset} = LLM.create_provider(new)
    refute changeset.valid?
    refute Repo.get_by(Provider, name: new.name)
  end

  test "a blank key on an edit keeps the stored one" do
    {:ok, provider} =
      LLM.create_provider(attrs(%{host: "https://llm.example.com", api_key: "sk-keep"}))

    assert {:ok, updated} = LLM.update_provider(provider, %{model: "m2", api_key: nil})
    assert updated.credentials == provider.credentials
    assert Client.resolve_api_key(updated) == "sk-keep"
  end

  test "moving the provider to another host with the key kept is refused" do
    {:ok, provider} =
      LLM.create_provider(attrs(%{host: "https://llm.example.com", api_key: "sk-host"}))

    assert {:error, changeset} =
             LLM.update_provider(provider, %{host: "https://other.example.com"})

    refute changeset.valid?
  end

  test "a call sends the key resolved for the provider's host" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    {:ok, provider} =
      LLM.create_provider(
        attrs(%{host: host, api_key: "sk-call", headers: %{"X-Org" => "org-call"}})
      )

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-call"]
      assert Plug.Conn.get_req_header(conn, "x-org") == ["org-call"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"choices" => [%{"message" => %{"content" => "hi"}}]})
      )
    end)

    assert {:ok, "hi"} = Client.call_provider(provider, "hello", nil)
  end

  test "deleting the provider deletes its secrets" do
    {:ok, provider} =
      LLM.create_provider(
        attrs(%{host: "https://llm.example.com", api_key: "sk-del", headers: %{"X-Org" => "o"}})
      )

    owned = names(provider)
    assert length(owned) == 2

    {:ok, _} = LLM.delete_provider(provider)
    assert Enum.all?(owned, &is_nil(Secrets.get(&1)))
  end
end
