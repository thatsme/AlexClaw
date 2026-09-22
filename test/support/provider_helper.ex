defmodule AlexClaw.ProviderHelper do
  @moduledoc """
  Provider rows written straight to the database, past `AlexClaw.LLM`'s rules.

  Enabling a second local provider is refused there, on purpose. A router test
  still has to describe a database that holds two of them — an older
  installation's, or one edited outside the admin UI — and check what the
  router does with it.
  """
  alias AlexClaw.LLM.Provider
  alias AlexClaw.Repo

  @doc "Insert a provider, whatever `AlexClaw.LLM.create_provider/1` would say about it."
  @spec insert!(map()) :: Provider.t()
  def insert!(attrs) do
    defaults = %{name: "p", type: "openai_compatible", model: "m", tier: "local", enabled: true}

    %Provider{}
    |> Provider.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
