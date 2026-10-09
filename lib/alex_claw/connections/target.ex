defmodule AlexClaw.Connections.Target do
  @moduledoc """
  Keeps a database connection away from AlexClaw itself and its own services
  (reports/SQLREAD_ATTACKER_REVIEW.md L7).

  A host is refused when it is, or resolves to, a loopback, "this network"
  or link-local address, or any address in AlexClaw's own networks — the
  compose networks its database, OpenBao and the web automator are on,
  configured as `:connection_internal_networks` (CIDR strings). A customer's
  server on a private network of its own is a normal target, so private
  ranges as such are not refused.

  Checked when a connection is saved and again before every connect: a name
  that does not resolve at save is checked once it does, and one that
  resolves elsewhere later is refused then.
  """
  import Bitwise

  # Loopback, "this network", link-local; ::1, ::, fe80::/10.
  @always_v4 [{0x7F000000, 8}, {0x00000000, 8}, {0xA9FE0000, 16}]
  @always_v6 [{1, 128}, {0, 128}, {0xFE80 <<< 112, 10}]

  @doc """
  `:ok`, or the reason `host` may not be a connection's server. A name that
  does not resolve is not refused here: it cannot be connected to either.
  """
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(host) when is_binary(host), do: refused(host, addresses(host, &resolve/1))

  @doc """
  `check/1` without a name lookup — for a save's transaction, which must not
  wait on a resolver (F8): an address literal, or `localhost`, is judged; any
  other name passes here and is resolved by `check/1` before the transaction
  and before every connect.
  """
  @spec check_literal(String.t()) :: :ok | {:error, String.t()}
  def check_literal(host) when is_binary(host),
    do: refused(host, addresses(host, &localhost/1))

  defp refused(host, addresses) do
    if Enum.any?(addresses, &internal?/1),
      do:
        {:error,
         "#{host} is one of AlexClaw's own addresses: a connection reads a customer's database"},
      else: :ok
  end

  defp addresses(host, name_lookup) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> [address]
      {:error, _not_an_address} -> name_lookup.(String.to_charlist(host))
    end
  end

  # The one name that means this machine without asking a resolver.
  defp localhost(name) do
    if String.downcase(to_string(name)) in ["localhost", "localhost."],
      do: [{127, 0, 0, 1}],
      else: []
  end

  defp resolve(name), do: lookup(name, :inet) ++ lookup(name, :inet6)

  defp lookup(name, family) do
    case :inet.getaddrs(name, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  # The IPv4-mapped IPv6 form of an IPv4 address is that address.
  defp internal?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: internal?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  defp internal?({a, b, c, d}) do
    value = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    in_ranges?(value, 32, @always_v4 ++ configured())
  end

  defp internal?(address) when tuple_size(address) == 8 do
    value = address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))
    in_ranges?(value, 128, @always_v6)
  end

  defp in_ranges?(value, bits, ranges),
    do:
      Enum.any?(ranges, fn {first, prefix} ->
        value >>> (bits - prefix) == first >>> (bits - prefix)
      end)

  # AlexClaw's own IPv4 networks, from the configuration: no default.
  defp configured do
    :alex_claw
    |> Application.fetch_env!(:connection_internal_networks)
    |> Enum.map(&cidr/1)
  end

  defp cidr(text) do
    [address, prefix] = String.split(text, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(address))
    {a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d, String.to_integer(prefix)}
  end
end
