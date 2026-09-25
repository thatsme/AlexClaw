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
  started only for a resource that is committed. `requester` is recorded on
  the row for that write; without one, the work is unattended.
  """
  @spec discover(Resource.t(), AlexClaw.ControlPlane.requester()) :: {:ok, pid()} | :ignore | :ok
  def discover(resource, requester \\ AlexClaw.ControlPlane.unattended())

  def discover(%Resource{type: "api"} = resource, requester),
    do: ApiDiscovery.run_async(resource, requester)

  def discover(_resource, _requester), do: :ok

  @spec delete_resource(Resource.t()) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
  def delete_resource(%Resource{} = resource) do
    Repo.delete(resource)
  end

  @spec list_by_tags([String.t()]) :: [Resource.t()]
  @doc """
  `resource` with its credentials taken out, for every reader outside core
  code (SkillAPI, MCP): the `auth` block is dropped, a password in the URL is
  replaced, and the values a recording captured — and the step descriptions
  that could repeat them — are replaced.
  """
  @spec redacted(Resource.t()) :: Resource.t()
  def redacted(%Resource{metadata: metadata, url: url} = resource) do
    %{resource | metadata: redacted_metadata(metadata || %{}), url: redacted_url(url)}
  end

  defp redacted_metadata(metadata) do
    metadata
    |> Map.drop(["auth"])
    |> redacted_steps()
  end

  defp redacted_steps(%{"steps" => steps} = metadata) when is_list(steps),
    do: %{metadata | "steps" => Enum.map(steps, &redacted_step/1)}

  defp redacted_steps(metadata), do: metadata

  # A step that carries a value (fill, select) is a step whose value and
  # description may hold what was typed.
  defp redacted_step(%{"value" => value} = step) when value not in [nil, ""] do
    step
    |> Map.put("value", "[REDACTED]")
    |> Map.replace("description", "[REDACTED]")
  end

  defp redacted_step(step), do: step

  defp redacted_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{userinfo: nil} -> url
      uri -> URI.to_string(%{uri | userinfo: "REDACTED"})
    end
  end

  defp redacted_url(url), do: url

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
