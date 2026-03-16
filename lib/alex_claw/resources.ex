defmodule AlexClaw.Resources do
  @moduledoc """
  Context for managing resources (feeds, URLs, documents, APIs).
  """
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Resources.Resource

  @spec list_resources(map()) :: [Resource.t()]
  def list_resources(filters \\ %{}) do
    Resource
    |> maybe_filter_type(filters[:type])
    |> maybe_filter_enabled(filters[:enabled])
    |> maybe_filter_tags(filters[:tags])
    |> order_by(:name)
    |> Repo.all()
  end

  @spec get_resource(integer()) :: {:ok, Resource.t()} | {:error, :not_found}
  def get_resource(id) do
    case Repo.get(Resource, id) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  @spec get_resource!(integer()) :: Resource.t()
  def get_resource!(id), do: Repo.get!(Resource, id)

  @spec create_resource(map()) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def create_resource(attrs) do
    %Resource{}
    |> Resource.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_resource(Resource.t(), map()) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def update_resource(%Resource{} = resource, attrs) do
    resource
    |> Resource.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_resource(Resource.t()) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def delete_resource(%Resource{} = resource) do
    Repo.delete(resource)
  end

  @spec list_by_tags([String.t()]) :: [Resource.t()]
  def list_by_tags(tags) when is_list(tags) do
    Resource
    |> where([r], fragment("? && ?", r.tags, ^tags))
    |> where([r], r.enabled == true)
    |> order_by(:name)
    |> Repo.all()
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [r], r.type == ^type)

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled), do: where(query, [r], r.enabled == ^enabled)

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query
  defp maybe_filter_tags(query, tags), do: where(query, [r], fragment("? && ?", r.tags, ^tags))
end
