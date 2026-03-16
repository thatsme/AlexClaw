defmodule AlexClaw.Workflows.SkillRegistry do
  @moduledoc """
  Maps string skill names to their implementing modules.
  """

  @registry %{
    "rss_collector" => AlexClaw.Skills.RSSCollector,
    "web_search" => AlexClaw.Skills.WebSearch,
    "web_browse" => AlexClaw.Skills.WebBrowse,
    "research" => AlexClaw.Skills.Research,
    "conversational" => AlexClaw.Skills.Conversational,
    "llm_transform" => AlexClaw.Workflows.LLMTransform,
    "telegram_notify" => AlexClaw.Skills.TelegramNotify,
    "api_request" => AlexClaw.Skills.ApiRequest,
    "github_security_review" => AlexClaw.Skills.GitHubSecurityReview,
    "google_calendar" => AlexClaw.Skills.GoogleCalendar,
    "google_tasks" => AlexClaw.Skills.GoogleTasks,
    "web_automation" => AlexClaw.Skills.WebAutomation
  }

  @doc "Resolve a skill name string to its module. Returns {:ok, module} or {:error, :unknown_skill}."
  @spec resolve(String.t()) :: {:ok, module()} | {:error, :unknown_skill}
  def resolve(name) when is_binary(name) do
    case Map.get(@registry, name) do
      nil -> {:error, :unknown_skill}
      module -> {:ok, module}
    end
  end

  @doc "List all registered skill names."
  @spec list_skills() :: [String.t()]
  def list_skills do
    Map.keys(@registry) |> Enum.sort()
  end

  @doc "List all registered skills as {name, module} pairs."
  @spec list_all() :: [{String.t(), module()}]
  def list_all do
    @registry |> Enum.sort_by(&elem(&1, 0))
  end
end
