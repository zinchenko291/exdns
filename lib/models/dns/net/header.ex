defmodule Models.Dns.Net.Header do
  @moduledoc false
  require Logger
  alias Models.Dns.Net.Header

  @type t :: %Header{}
  defstruct [
    :id,
    :qr,
    :opcode,
    :aa,
    :tc,
    :rd,
    :ra,
    :z,
    :rcode,
    :qdcount,
    :ancount,
    :nscount,
    :arcount
  ]

  @spec deserialize(<<_::96>>) :: {:error, map()} | {:ok, t()}
  def deserialize(binary) when is_bitstring(binary) do
    Logger.debug("[Header] deserialize size=#{byte_size(binary)}")
    <<
      id::16,
      qr::1,
      opcode::4,
      aa::1,
      tc::1,
      rd::1,
      ra::1,
      z::3,
      rcode::4,
      qdcount::16,
      ancount::16,
      nscount::16,
      arcount::16
    >> = binary

    %Header{
      id: id,
      qr: qr,
      opcode: opcode,
      aa: aa,
      tc: tc,
      rd: rd,
      ra: ra,
      z: z,
      rcode: rcode,
      qdcount: qdcount,
      ancount: ancount,
      nscount: nscount,
      arcount: arcount
    }
    |> validate_header()
  end

  @doc """
  Serialize a header struct into the 12-byte DNS header wire format.
  """
  @spec serialize(t() | map()) :: {:ok, binary()} | {:error, map()}
  def serialize(%Header{} = header) do
    with {:ok, header} <- validate_header(header) do
      binary =
        <<
          header.id::16,
          header.qr::1,
          header.opcode::4,
          header.aa::1,
          header.tc::1,
          header.rd::1,
          header.ra::1,
          header.z::3,
          header.rcode::4,
          header.qdcount::16,
          header.ancount::16,
          header.nscount::16,
          header.arcount::16
        >>

      Logger.debug("[Header] serialize id=#{header.id}")
      {:ok, binary}
    end
  end

  def serialize(attrs) when is_map(attrs) do
    attrs
    |> struct(Header)
    |> serialize()
  end

  defp validate_header(%Header{} = header) do
    {ok_fields, errors} =
      header
      |> Map.from_struct()
      |> Enum.reduce({%{}, %{}}, fn {key, value}, {ok_acc, err_acc} ->
        case validate_arg(key, value) do
          {:ok, v} -> {Map.put(ok_acc, key, v), err_acc}
          {:error, reason} -> {ok_acc, Map.put(err_acc, key, reason)}
        end
      end)

    if map_size(errors) > 0 do
      {:error, errors}
    else
      {:ok, struct(Header, ok_fields)}
    end
  end

  # --- helpers

  defp validate_bool(_field, value) when value in [0, 1], do: {:ok, value}
  defp validate_bool(field, _value), do: {:error, "#{field} must be 0 or 1"}

  defp validate_u16(_field, value) when is_integer(value) and value in 0x0..0xFFFF,
    do: {:ok, value}

  defp validate_u16(field, _value), do: {:error, "#{field} must be between 0 and 65535"}

  # --- validations

  defp validate_arg(:id, value), do: validate_u16(:id, value)

  defp validate_arg(:qr, value), do: validate_bool(:qr, value)
  defp validate_arg(:aa, value), do: validate_bool(:aa, value)
  defp validate_arg(:tc, value), do: validate_bool(:tc, value)
  defp validate_arg(:rd, value), do: validate_bool(:rd, value)
  defp validate_arg(:ra, value), do: validate_bool(:ra, value)

  defp validate_arg(:opcode, value) when is_integer(value) do
    if value in 0..2 do
      {:ok, value}
    else
      {:error, "opcode must be between 0 and 2"}
    end
  end

  defp validate_arg(:opcode, _value), do: {:error, "opcode must be an integer"}

  defp validate_arg(:z, value) when is_integer(value) and value in 0..7, do: {:ok, value}

  defp validate_arg(:z, _value), do: {:error, "z must be between 0 and 7"}

  defp validate_arg(:rcode, value) when is_integer(value) and value in 0..15,
    do: {:ok, value}

  defp validate_arg(:rcode, _value), do: {:error, "rcode must be between 0 and 15"}

  defp validate_arg(:qdcount, value), do: validate_u16(:qdcount, value)
  defp validate_arg(:ancount, value), do: validate_u16(:ancount, value)
  defp validate_arg(:nscount, value), do: validate_u16(:nscount, value)
  defp validate_arg(:arcount, value), do: validate_u16(:arcount, value)

  defp validate_arg(_field, value), do: {:ok, value}
end

defimpl Collectable, for: Models.Dns.Net.Header do
  alias Models.Dns.Net.Header

  def into(header_acc) do
    collector = fn
      map, {:cont, {key, value}} -> Map.put(map, key, value)
      map, :done -> map
      _map, :halt -> :ok
    end

    {header_acc, collector}
  end
end
