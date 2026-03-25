defmodule AlexClaw.Auth.PolicyEngine do
  @moduledoc """
  Evaluates authorization decisions based on context and policy rules.

  Checks in order:
  1. Core skills → always allow (fast path)
  2. Chain depth → deny if too deep
  3. Capability token → deny if token present and lacks permission
  4. Policy rules → rate_limit, time_window, chain_restriction, permission_override
  5. Flat permission list → deny if permission not declared
  """

  alias AlexClaw.Auth.{AuthContext, AuditLog, CapabilityToken, Policy, SkillRateLimiter}
  alias AlexClaw.Repo

  import Ecto.Query, only: [from: 2]

  @max_chain_depth 3
  @policy_cache_key {__MODULE__, :policies}
  @policy_cache_ttl 30_000

  @doc """
  Evaluate an authorization context.

  Returns `:allow` or `{:deny, reason}`.
  """
  @spec evaluate(AuthContext.t(), :all | [atom()]) :: :allow | {:deny, String.t()}
  def evaluate(%AuthContext{caller_type: :core} = ctx, :all) do
    AuditLog.log_allow(ctx)
    :allow
  end

  def evaluate(%AuthContext{} = ctx, permissions) when is_list(permissions) do
    with :ok <- check_chain_depth(ctx),
         :ok <- check_token(ctx),
         :ok <- check_policies(ctx),
         :ok <- check_permission_list(ctx, permissions) do
      AuditLog.log_allow(ctx)
      :allow
    else
      {:deny, reason} = denial ->
        AuditLog.log_deny(ctx, reason)
        denial
    end
  end

  def evaluate(%AuthContext{} = ctx, _) do
    reason = "unknown permission state"
    AuditLog.log_deny(ctx, reason)
    {:deny, reason}
  end

  @doc "Reload cached policies from DB."
  def reload_policies do
    :persistent_term.erase(@policy_cache_key)
    load_policies()
  end

  # --- Core checks ---

  defp check_chain_depth(%AuthContext{chain_depth: depth}) when depth > @max_chain_depth do
    {:deny, "chain depth #{depth} exceeds maximum #{@max_chain_depth}"}
  end

  defp check_chain_depth(_ctx), do: :ok

  defp check_token(%AuthContext{token: nil}), do: :ok

  defp check_token(%AuthContext{token: %CapabilityToken{} = token, permission: permission}) do
    case CapabilityToken.verify(token) do
      {:ok, _perms} ->
        if CapabilityToken.has_permission?(token, permission) do
          :ok
        else
          {:deny, "token does not grant :#{permission}"}
        end

      {:error, :invalid_token} -> {:deny, "invalid capability token"}
      {:error, :token_expired} -> {:deny, "capability token expired"}
      {:error, :max_depth_exceeded} -> {:deny, "token max depth exceeded"}
    end
  end

  defp check_token(_ctx), do: :ok

  defp check_permission_list(%AuthContext{permission: permission}, permissions) do
    if permission in permissions do
      :ok
    else
      {:deny, "permission :#{permission} not declared"}
    end
  end

  # --- Policy rule evaluation ---

  defp check_policies(%AuthContext{} = ctx) do
    policies = load_policies()

    Enum.reduce_while(policies, :ok, fn policy, :ok ->
      case evaluate_policy(policy, ctx) do
        :ok -> {:cont, :ok}
        {:deny, _} = denial -> {:halt, denial}
      end
    end)
  end

  defp evaluate_policy(%Policy{rule_type: "rate_limit", config: config}, ctx) do
    permission = config["permission"]
    max_calls = config["max_calls"] || 10
    window = config["window_seconds"] || 60

    if permission == nil or permission == to_string(ctx.permission) do
      caller_key = inspect(ctx.caller)

      case SkillRateLimiter.check(caller_key, ctx.permission, max_calls, window) do
        :ok -> :ok
        {:error, :rate_limited} -> {:deny, "rate limit exceeded: max #{max_calls}/#{window}s"}
      end
    else
      :ok
    end
  end

  defp evaluate_policy(%Policy{rule_type: "time_window", config: config}, ctx) do
    permission = config["permission"]

    if permission == nil or permission == to_string(ctx.permission) do
      now = DateTime.utc_now()
      hour = now.hour
      start_hour = config["deny_start_hour"] || 0
      end_hour = config["deny_end_hour"] || 6

      if hour >= start_hour and hour < end_hour do
        {:deny, "blocked by time window policy (#{start_hour}:00-#{end_hour}:00 UTC)"}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp evaluate_policy(%Policy{rule_type: "chain_restriction", config: config}, ctx) do
    caller_pattern = config["caller_pattern"]

    if caller_pattern && String.contains?(inspect(ctx.caller), caller_pattern) do
      if ctx.chain_depth > 0 do
        {:deny, "chain restriction: #{caller_pattern} cannot invoke other skills"}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp evaluate_policy(%Policy{rule_type: "permission_override", config: config}, ctx) do
    permission = config["permission"]
    action = config["action"]

    if permission == to_string(ctx.permission) do
      case config["expires_at"] do
        nil -> apply_override(action)
        expires_str ->
          case DateTime.from_iso8601(expires_str) do
            {:ok, expires, _} ->
              if DateTime.compare(DateTime.utc_now(), expires) == :lt do
                apply_override(action)
              else
                :ok
              end

            _ ->
              :ok
          end
      end
    else
      :ok
    end
  end

  defp evaluate_policy(%Policy{rule_type: "skill_allowlist", config: config}, ctx) do
    permission = config["permission"]
    allowed = config["allowed_skills"] || []

    if permission == nil or permission == to_string(ctx.permission) do
      caller_name =
        ctx.caller
        |> inspect()
        |> String.replace("Elixir.", "")

      skill_name =
        caller_name
        |> String.split(".")
        |> List.last()
        |> Macro.underscore()

      if Enum.any?(allowed, fn name ->
        name == skill_name or name == caller_name or String.contains?(caller_name, name)
      end) do
        :ok
      else
        {:deny, "skill_allowlist: #{skill_name} not in allowed list for :#{permission}"}
      end
    else
      :ok
    end
  end

  defp evaluate_policy(_policy, _ctx), do: :ok

  defp apply_override("deny"), do: {:deny, "denied by permission override policy"}
  defp apply_override(_), do: :ok

  # --- Policy cache ---

  defp load_policies do
    case :persistent_term.get(@policy_cache_key, nil) do
      {policies, loaded_at} ->
        if System.monotonic_time(:millisecond) - loaded_at < @policy_cache_ttl do
          policies
        else
          fetch_and_cache_policies()
        end

      nil ->
        fetch_and_cache_policies()
    end
  end

  defp fetch_and_cache_policies do
    policies =
      try do
        Repo.all(
          from(p in Policy,
            where: p.enabled == true,
            order_by: [desc: p.priority]
          )
        )
      rescue
        _ -> []
      end

    :persistent_term.put(@policy_cache_key, {policies, System.monotonic_time(:millisecond)})
    policies
  end
end
