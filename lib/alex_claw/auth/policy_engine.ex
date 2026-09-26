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

  require Logger

  alias AlexClaw.Auth.{AuditLog, AuthContext, CapabilityToken, Policy, SkillRateLimiter}
  alias AlexClaw.Repo

  import Ecto.Query, only: [from: 2]

  @max_chain_depth 3
  @policy_cache_key {__MODULE__, :policies}
  @policy_cache_ttl 30_000

  @doc """
  Evaluate an authorization context.

  Returns `:allow` or `{:deny, reason}`.

  - Core skills with `:all` permissions get a fast-path allow.
  - Dynamic skills go through chain depth, token, policy, and permission checks.
  - MCP calls go through all policy checks (no fast path, no token/permission list
    since MCP auth is Bearer token at the transport layer + policies at this layer).
  """
  @spec evaluate(AuthContext.t(), :all | [atom()]) :: :allow | {:deny, String.t()}
  def evaluate(%AuthContext{caller_type: :core} = ctx, :all) do
    AuditLog.log_allow(ctx)
    :allow
  end

  def evaluate(%AuthContext{caller_type: :mcp} = ctx, _permissions) do
    case check_policies(ctx) do
      :ok ->
        AuditLog.log_allow(ctx)
        :allow

      {:deny, reason} = denial ->
        AuditLog.log_deny(ctx, reason)
        denial
    end
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
  @spec reload_policies() :: [Policy.t()] | :unavailable
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

      {:error, :invalid_token} ->
        {:deny, "invalid capability token"}

      {:error, :token_expired} ->
        {:deny, "capability token expired"}

      {:error, :max_depth_exceeded} ->
        {:deny, "token max depth exceeded"}
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

  defp check_policies(%AuthContext{} = ctx), do: checked_against(load_policies(), ctx)

  # Policies that cannot be read deny (S8 M15): "no policies" would allow.
  defp checked_against(:unavailable, _ctx), do: {:deny, "policies unavailable"}

  defp checked_against(policies, ctx) do
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
    override_for(config["permission"] == to_string(ctx.permission), config)
  end

  defp evaluate_policy(
         %Policy{rule_type: "mcp_restriction", config: config},
         %AuthContext{caller_type: :mcp} = ctx
       ) do
    mcp_restriction(tool_matches?(ctx.tool_name, config), ctx, config)
  end

  defp evaluate_policy(%Policy{rule_type: "mcp_restriction"}, _ctx), do: :ok

  defp evaluate_policy(_policy, _ctx), do: :ok

  # "exact" is the safe default for a deny rule; "contains" stays the fallback so
  # patterns written before the mode existed keep matching as they did.
  defp tool_matches?(nil, _config), do: false

  defp tool_matches?(tool_name, %{"tool_pattern" => pattern} = config) when is_binary(pattern) do
    case config["match"] do
      "exact" -> tool_name == pattern
      _ -> String.contains?(tool_name, pattern)
    end
  end

  defp tool_matches?(_tool_name, _config), do: false

  defp mcp_restriction(false, _ctx, _config), do: :ok
  defp mcp_restriction(true, _ctx, %{"action" => action}) when action != "deny", do: :ok

  defp mcp_restriction(true, ctx, config) do
    {:deny,
     "MCP restriction: tool '#{ctx.tool_name}' blocked by pattern '#{config["tool_pattern"]}'"}
  end

  defp override_for(false, _config), do: :ok
  defp override_for(true, %{"expires_at" => nil} = config), do: apply_override(config["action"])

  defp override_for(true, %{"expires_at" => expires_str} = config) do
    case DateTime.from_iso8601(expires_str) do
      {:ok, expires, _} -> apply_unexpired(DateTime.compare(DateTime.utc_now(), expires), config)
      _ -> :ok
    end
  end

  defp override_for(true, config), do: apply_override(config["action"])

  defp apply_unexpired(:lt, config), do: apply_override(config["action"])
  defp apply_unexpired(_comparison, _config), do: :ok

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

  # A database that cannot answer is not "no policies": nothing is cached, and
  # the caller denies.
  defp fetch_and_cache_policies do
    from(p in Policy, where: p.enabled == true, order_by: [desc: p.priority])
    |> Repo.all()
    |> cached()
  rescue
    error ->
      Logger.warning("Policies could not be read: #{Exception.message(error)}")
      :unavailable
  end

  defp cached(policies) do
    :persistent_term.put(@policy_cache_key, {policies, System.monotonic_time(:millisecond)})
    policies
  end
end
