defmodule AlexClaw.Skills.Dynamic.NvdCveMonitor do
  @moduledoc """
  Monitors NIST NVD for new CVEs via the 2.0 JSON API.
  Fetches recent vulnerabilities, filters by severity, stores in memory
  with embeddings, and notifies via Telegram.

  Config keys:
    - hours_back: how far back to look (default: 24)
    - min_severity: minimum CVSS severity to report — LOW, MEDIUM, HIGH, CRITICAL (default: HIGH)
    - max_results: max CVEs to process (default: 20)
    - api_key: NVD API key for higher rate limits (optional)
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @nvd_api "https://services.nvd.nist.gov/rest/json/cves/2.0"
  @severity_order %{"LOW" => 1, "MEDIUM" => 2, "HIGH" => 3, "CRITICAL" => 4}

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:web_read, :memory_read, :memory_write, :telegram_send, :config_read]

  @impl true
  def description, do: "NVD CVE monitor — fetches recent vulnerabilities from NIST NVD 2.0 API"

  @impl true
  def run(args) do
    config = args[:config] || %{}
    hours_back = to_int(config["hours_back"], 24)
    min_severity = config["min_severity"] || "HIGH"
    max_results = to_int(config["max_results"], 20)
    api_key = config["api_key"] || config_get("nvd.api_key", "")

    now = DateTime.utc_now()
    start = DateTime.add(now, -hours_back * 3600, :second)

    case fetch_cves(start, now, max_results, api_key) do
      {:ok, cves} ->
        filtered =
          cves
          |> filter_by_severity(min_severity)
          |> reject_seen()
          |> Enum.take(max_results)

        Enum.each(filtered, fn cve ->
          store_cve(cve)
          notify_cve(cve)
          Process.sleep(500)
        end)

        summary = build_summary(filtered)
        {:ok, if(summary == "", do: "No new CVEs above #{min_severity} severity.", else: summary)}

      {:error, reason} ->
        {:error, {:nvd_fetch_failed, reason}}
    end
  end

  # --- API ---

  defp fetch_cves(start_dt, end_dt, per_page, api_key) do
    start_str = Calendar.strftime(start_dt, "%Y-%m-%dT%H:%M:%S.000")
    end_str = Calendar.strftime(end_dt, "%Y-%m-%dT%H:%M:%S.000")

    url = "#{@nvd_api}?pubStartDate=#{start_str}&pubEndDate=#{end_str}&resultsPerPage=#{per_page}"

    headers =
      if api_key != "" do
        [{"apiKey", api_key}]
      else
        []
      end

    case SkillAPI.http_get(__MODULE__, url, headers: headers, receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        cves =
          (body["vulnerabilities"] || [])
          |> Enum.map(&parse_cve/1)
          |> Enum.reject(&is_nil/1)

        {:ok, cves}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_cve(%{"cve" => cve}) do
    id = cve["id"]

    description =
      (cve["descriptions"] || [])
      |> Enum.find(fn d -> d["lang"] == "en" end)
      |> case do
        %{"value" => v} -> v
        _ -> ""
      end

    {severity, score} = extract_cvss(cve)

    references =
      (cve["references"] || [])
      |> Enum.map(fn r -> r["url"] end)
      |> Enum.take(3)

    %{
      id: id,
      description: description,
      severity: severity,
      score: score,
      references: references,
      published: cve["published"],
      url: "https://nvd.nist.gov/vuln/detail/#{id}"
    }
  end

  defp parse_cve(_), do: nil

  defp extract_cvss(cve) do
    # Try CVSS v3.1 first, then v3.0, then v2.0
    metrics = cve["metrics"] || %{}

    cvss =
      get_first_cvss(metrics, "cvssMetricV31") ||
        get_first_cvss(metrics, "cvssMetricV30") ||
        get_first_cvss(metrics, "cvssMetricV2")

    case cvss do
      %{"cvssData" => %{"baseSeverity" => sev, "baseScore" => score}} -> {sev, score}
      %{"cvssData" => %{"baseScore" => score}} -> {severity_from_score(score), score}
      _ -> {"UNKNOWN", 0.0}
    end
  end

  defp get_first_cvss(metrics, key) do
    case metrics[key] do
      [first | _] -> first
      _ -> nil
    end
  end

  defp severity_from_score(score) when score >= 9.0, do: "CRITICAL"
  defp severity_from_score(score) when score >= 7.0, do: "HIGH"
  defp severity_from_score(score) when score >= 4.0, do: "MEDIUM"
  defp severity_from_score(_), do: "LOW"

  # --- Filtering ---

  defp filter_by_severity(cves, min_severity) do
    min_level = Map.get(@severity_order, min_severity, 3)

    Enum.filter(cves, fn cve ->
      level = Map.get(@severity_order, cve.severity, 0)
      level >= min_level
    end)
  end

  defp reject_seen(cves) do
    Enum.reject(cves, fn cve ->
      case SkillAPI.memory_exists?(__MODULE__, cve.url) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  # --- Store & Notify ---

  defp store_cve(cve) do
    content = """
    #{cve.id} [#{cve.severity} #{cve.score}]
    #{cve.description}
    References: #{Enum.join(cve.references, ", ")}
    """

    SkillAPI.memory_store(__MODULE__, :cve, String.trim(content),
      source: cve.url,
      metadata: %{
        cve_id: cve.id,
        severity: cve.severity,
        score: cve.score,
        published: cve.published
      }
    )
  end

  defp notify_cve(cve) do
    emoji =
      case cve.severity do
        "CRITICAL" -> "🔴"
        "HIGH" -> "🟠"
        "MEDIUM" -> "🟡"
        _ -> "🔵"
      end

    message = """
    #{emoji} *#{cve.id}* [#{cve.severity} #{cve.score}]
    #{escape_md(String.slice(cve.description, 0, 500))}
    #{cve.url}
    """

    SkillAPI.send_telegram(__MODULE__, String.trim(message))
  end

  defp build_summary(cves) when cves == [], do: ""

  defp build_summary(cves) do
    by_severity = Enum.group_by(cves, & &1.severity)

    parts =
      ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
      |> Enum.filter(&Map.has_key?(by_severity, &1))
      |> Enum.map(fn sev ->
        items = by_severity[sev]
        header = "**#{sev}** (#{length(items)})"
        details = Enum.map_join(items, "\n", fn cve ->
          "- #{cve.id} (#{cve.score}): #{String.slice(cve.description, 0, 150)}"
        end)
        "#{header}\n#{details}"
      end)

    Enum.join(parts, "\n\n")
  end

  # --- Helpers ---

  defp escape_md(text), do: String.replace(text, ~r/[*_`\[\]]/, "")

  defp config_get(key, default) do
    case SkillAPI.config_get(__MODULE__, key, default) do
      {:ok, value} when not is_nil(value) and value != "" -> value
      _ -> default
    end
  end

  defp to_int(nil, default), do: default
  defp to_int(val, _) when is_integer(val), do: val
  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_int(_, default), do: default
end
