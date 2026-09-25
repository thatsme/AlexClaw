defmodule AlexClaw.Auth.Policies do
  @moduledoc """
  Writes to the authorization policies (`AlexClaw.Auth.Policy`). Called from
  `AlexClaw.ControlPlane.Actions` only; `AlexClaw.Auth.PolicyEngine` reads them.
  """

  alias AlexClaw.Auth.Policy
  alias AlexClaw.Repo

  @doc "Create a policy."
  @spec create_policy(map()) :: {:ok, Policy.t()} | {:error, Ecto.Changeset.t()}
  def create_policy(attrs), do: %Policy{} |> Policy.changeset(attrs) |> Repo.insert()

  @doc "Update the policy `id` with `attrs`."
  @spec update_policy(integer() | String.t(), map()) ::
          {:ok, Policy.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_policy(id, attrs) do
    with {:ok, policy} <- fetch(id), do: policy |> Policy.changeset(attrs) |> Repo.update()
  end

  @doc "Turn the policy `id` on if it is off, off if it is on."
  @spec toggle_policy(integer() | String.t()) ::
          {:ok, Policy.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def toggle_policy(id) do
    with {:ok, policy} <- fetch(id),
         do: policy |> Policy.changeset(%{enabled: !policy.enabled}) |> Repo.update()
  end

  @doc "Delete the policy `id`."
  @spec delete_policy(integer() | String.t()) ::
          {:ok, Policy.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def delete_policy(id) do
    with {:ok, policy} <- fetch(id), do: Repo.delete(policy)
  end

  defp fetch(id) do
    case Repo.get(Policy, id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end
end
