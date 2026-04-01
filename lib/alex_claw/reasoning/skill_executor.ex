defmodule AlexClaw.Reasoning.SkillExecutor do
  @moduledoc """
  Executes skills within the reasoning loop, following the same security path
  as the workflow executor: whitelist → resolve → token → execute → sanitize.
  """

  require Logger

  alias AlexClaw.Workflows.SkillRegistry
  alias AlexClaw.Auth.{CapabilityToken, SafeExecutor}
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.ContentSanitizer

  @spec execute(String.t(), map(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def execute(skill_name, args, whitelist, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    with :ok <- check_whitelist(skill_name, whitelist),
         {:ok, module} <- SkillRegistry.resolve(skill_name),
         skill_type <- SkillRegistry.get_type(module) || :core,
         token <- mint_token(module, skill_type) do
      Process.put(:auth_chain_depth, 0)
      if token, do: Process.put(:auth_token, token)

      safe_opts = [timeout: timeout]

      result =
        CircuitBreaker.call(skill_name, fn ->
          SafeExecutor.run(module, args, skill_type, token, safe_opts)
        end)

      result
      |> normalize_result()
      |> maybe_sanitize(skill_name)
      |> extract_text()
    end
  end

  @spec list_whitelisted_skills([String.t()]) :: [{String.t(), String.t()}]
  def list_whitelisted_skills(whitelist) do
    whitelist
    |> Enum.map(fn name ->
      case SkillRegistry.resolve(name) do
        {:ok, module} ->
          desc =
            if function_exported?(module, :description, 0),
              do: module.description(),
              else: "No description available"

          {name, desc}

        {:error, _} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec skill_description(String.t()) :: String.t()
  def skill_description(skill_name) do
    case SkillRegistry.resolve(skill_name) do
      {:ok, module} ->
        if function_exported?(module, :description, 0),
          do: module.description(),
          else: "No description available"

      {:error, _} ->
        "Unknown skill"
    end
  end

  # --- Private ---

  defp check_whitelist(skill_name, whitelist) do
    if skill_name in whitelist do
      :ok
    else
      Logger.warning("[ReasoningSkillExecutor] Skill #{skill_name} not in whitelist")
      {:error, :not_whitelisted}
    end
  end

  defp mint_token(_module, :core), do: nil

  defp mint_token(module, :dynamic) do
    case SkillRegistry.get_permissions(module) do
      perms when is_list(perms) -> CapabilityToken.mint(perms)
      _ -> nil
    end
  end

  defp normalize_result({:ok, result, _branch}), do: {:ok, result}
  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, :circuit_open}), do: {:error, :circuit_open}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp maybe_sanitize({:ok, result}, skill_name) do
    if SkillRegistry.external?(skill_name) do
      {:ok, ContentSanitizer.sanitize(result, skill: skill_name)}
    else
      {:ok, result}
    end
  end

  defp maybe_sanitize({:error, _} = err, _skill_name), do: err

  defp extract_text({:ok, result}) when is_binary(result), do: {:ok, result}
  defp extract_text({:ok, result}), do: {:ok, inspect(result)}
  defp extract_text({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp extract_text({:error, reason}), do: {:error, inspect(reason)}
end
