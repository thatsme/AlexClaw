defmodule AlexClaw.Secrets.Mask do
  @moduledoc """
  Masks every value `AlexClaw.Secrets` has handed out, wherever it could
  travel next (S8 H1, H8; THREAT_MODEL P1).

  A value resolved from OpenBao is remembered here, in memory only (an ETS
  table this process owns; never written anywhere), and `mask/1` replaces it
  with `[secret]` in any term: a string, or the strings inside a map, list,
  tuple or struct. It is applied where values could come back — a run's step
  results, errors and outcomes, the gateways, audit rows — and, through
  `log_filter/2`, to every log line, crash reports included. So an API that
  echoes a token, or an HTTP client error quoting a malformed header, does not
  carry the value any further.

  Values shorter than 6 characters are not remembered: masking them would
  mangle ordinary text, and no credential AlexClaw holds is that short.
  """
  use GenServer

  @table :alexclaw_secret_mask
  @marker "[secret]"
  @min_length 6

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Remember `value` so it is masked from now on. Short or non-text values are ignored."
  @spec register(term()) :: :ok
  def register(value) when is_binary(value) and byte_size(value) >= @min_length,
    do: remember(:ets.whereis(@table), value)

  def register(_value), do: :ok

  defp remember(:undefined, _value), do: :ok

  defp remember(_table, value) do
    :ets.insert(@table, {value})
    :ok
  end

  @doc "`term` with every remembered value replaced by `#{@marker}`."
  @spec mask(term()) :: term()
  def mask(term), do: masked(term, values())

  defp values, do: values(:ets.whereis(@table))

  defp values(:undefined), do: []

  # Longest first, so a value that contains another is masked whole.
  defp values(_table) do
    @table
    |> :ets.select([{{:"$1"}, [], [:"$1"]}])
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp masked(term, []), do: term

  defp masked(text, values) when is_binary(text),
    do: Enum.reduce(values, text, &String.replace(&2, &1, @marker))

  # Element by element, so an improper list (an iolist's tail) is walked too.
  defp masked([head | tail], values), do: [masked(head, values) | masked(tail, values)]

  defp masked(tuple, values) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> masked(values) |> List.to_tuple()

  # A struct keeps its type: its fields are masked, its keys are atoms.
  defp masked(%_{} = struct, values),
    do: Map.merge(struct, struct |> Map.from_struct() |> masked(values))

  defp masked(%{} = map, values),
    do: Map.new(map, fn {k, v} -> {masked(k, values), masked(v, values)} end)

  defp masked(other, _values), do: other

  @doc """
  A `:logger` primary filter: a log event whose text holds a remembered value
  has it masked. Installed at application start. An event that holds none is
  passed on as it is.
  """
  @spec log_filter(:logger.log_event(), term()) :: :logger.filter_return()
  def log_filter(%{msg: msg, meta: meta} = event, _extra) do
    event_masked(event, msg, meta, values())
  rescue
    # A filter that raises is removed by :logger, which would stop masking.
    _error -> event
  end

  defp event_masked(event, _msg, _meta, []), do: event

  defp event_masked(event, msg, meta, values) do
    text = event_text(msg, meta)
    masked = masked(text, values)
    if masked == text, do: event, else: %{event | msg: {:string, masked}}
  end

  defp event_text({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp event_text({:report, report}, %{report_cb: callback}) when is_function(callback, 1) do
    {format, args} = callback.(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp event_text({:report, report}, _meta), do: inspect(report, limit: :infinity)

  defp event_text({format, args}, _meta),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()
end
