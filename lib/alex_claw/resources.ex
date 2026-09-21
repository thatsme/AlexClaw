defmodule AlexClaw.Resources do
  @moduledoc """
  Context for managing resources (feeds, URLs, documents, APIs).
  """
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Resources.ApiDiscovery
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

  @doc """
  Create a resource. An API resource starts discovery once created, unless
  `skip_discovery: true` — which a caller inside a transaction passes, and
  calls `discover/1` after commit instead.
  """
  @spec create_resource(map(), keyword()) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def create_resource(attrs, opts \\ []) do
    result =
      %Resource{}
      |> Resource.changeset(attrs)
      |> Repo.insert()

    unless opts[:skip_discovery] do
      with {:ok, resource} <- result, do: discover(resource)
    end

    result
  end

  @spec update_resource(Resource.t(), map(), keyword()) ::
          {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def update_resource(%Resource{} = resource, attrs, opts \\ []) do
    result =
      resource
      |> Resource.changeset(attrs)
      |> Repo.update()

    unless opts[:skip_discovery] do
      with {:ok, updated} <- result, do: discover(updated)
    end

    result
  end

  @doc """
  Start discovering an API resource's endpoints, in the background. Discovery
  fetches the API and then writes what it found to the resource, so it is
  started only for a resource that is committed.
  """
  @spec discover(Resource.t()) :: {:ok, pid()} | :ignore | :ok
  def discover(%Resource{type: "api"} = resource), do: ApiDiscovery.run_async(resource)
  def discover(_resource), do: :ok

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
