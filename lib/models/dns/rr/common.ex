defmodule Models.Dns.Rr.Common do
  @moduledoc false

  alias Models.Dns.Name

  defguardp is_octet(value) when is_integer(value) and value >= 0 and value <= 255
  defguardp is_u16(value) when is_integer(value) and value >= 0 and value <= 0xFFFF

  @type header_info :: %{
          name: String.t(),
          type: non_neg_integer(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          rdlength: non_neg_integer(),
          rdata_offset: non_neg_integer(),
          next_offset: non_neg_integer()
        }

  @spec serialize_rr(map(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, String.t()}
  def serialize_rr(%{name: name, class: class, ttl: ttl}, type, rdata)
      when is_integer(type) and type in 0..0xFFFF do
    with {:ok, name_wire} <- Name.encode(name),
         {:ok, class} <- validate_u16(:class, class),
         {:ok, ttl} <- validate_u32(:ttl, ttl),
         {:ok, rdlength} <- validate_u16(:rdlength, byte_size(rdata)) do
      rr =
        name_wire <>
          <<type::16, class::16, ttl::32, rdlength::16>> <>
          rdata

      {:ok, rr}
    end
  end

  def serialize_rr(_map, _type, _rdata),
    do: {:error, "invalid RR arguments for serialization"}

  @spec deserialize_rr(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, header_info()} | {:error, String.t()}
  def deserialize_rr(message, offset, expected_type)
      when is_binary(message) and is_integer(offset) and offset >= 0 do
    with {:ok, name, cursor} <- Name.decode(message, offset),
         {:ok, type, class, ttl, rdlength} <- read_fixed_header(message, cursor),
         :ok <- ensure_type(type, expected_type),
         data_offset <- cursor + 10,
         data_end <- data_offset + rdlength,
         true <- data_end <= byte_size(message) do
      {:ok,
       %{
         name: name,
         type: type,
         class: class,
         ttl: ttl,
         rdlength: rdlength,
         rdata_offset: data_offset,
         next_offset: data_end
       }}
    else
      {:error, _} = err -> err
      false -> {:error, "rr data (type #{expected_type}) truncated"}
    end
  end

  def deserialize_rr(_message, offset, _expected),
    do: {:error, "cannot deserialize RR at offset #{inspect(offset)}"}

  @spec encode_ipv4(:inet.ip4_address()) :: {:ok, binary()} | {:error, String.t()}
  def encode_ipv4({a, b, c, d}) when is_octet(a) and is_octet(b) and is_octet(c) and is_octet(d) do
    {:ok, <<a, b, c, d>>}
  end

  def encode_ipv4(_), do: {:error, "ipv4 address must be a 4-tuple of octets"}

  @spec decode_ipv4(binary()) :: {:ok, :inet.ip4_address()} | {:error, String.t()}
  def decode_ipv4(<<a, b, c, d>>), do: {:ok, {a, b, c, d}}
  def decode_ipv4(_), do: {:error, "ipv4 rdata must be 4 bytes"}

  @spec encode_ipv6(:inet.ip6_address()) :: {:ok, binary()} | {:error, String.t()}
  def encode_ipv6({a, b, c, d, e, f, g, h})
      when is_u16(a) and is_u16(b) and is_u16(c) and is_u16(d) and is_u16(e) and
             is_u16(f) and is_u16(g) and is_u16(h) do
    {:ok, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}
  end

  def encode_ipv6(_), do: {:error, "ipv6 address must be an 8-tuple of 16-bit segments"}

  @spec decode_ipv6(binary()) :: {:ok, :inet.ip6_address()} | {:error, String.t()}
  def decode_ipv6(
        <<
          a::16,
          b::16,
          c::16,
          d::16,
          e::16,
          f::16,
          g::16,
          h::16
        >>
      ),
      do: {:ok, {a, b, c, d, e, f, g, h}}

  def decode_ipv6(_), do: {:error, "ipv6 rdata must be 16 bytes"}

  @spec encode_txt_strings([binary()]) :: {:ok, binary()} | {:error, String.t()}
  def encode_txt_strings(strings) when is_list(strings) do
    reducer = fn string, {:ok, acc} ->
      case encode_txt_chunk(string) do
        {:ok, chunk} -> {:cont, {:ok, [chunk | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end

    case Enum.reduce_while(strings, {:ok, []}, reducer) do
      {:ok, chunks} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, _} = err ->
        err
    end
  end

  def encode_txt_strings(_), do: {:error, "txt record expects a list of binaries"}

  defp encode_txt_chunk(string) when is_binary(string) do
    if byte_size(string) > 255 do
      {:error, "txt chunk longer than 255 bytes"}
    else
      {:ok, [<<byte_size(string)>>, string]}
    end
  end

  defp encode_txt_chunk(_), do: {:error, "txt chunks must be binaries"}

  @spec decode_txt_strings(binary()) :: {:ok, [binary()]} | {:error, String.t()}
  def decode_txt_strings(binary) when is_binary(binary) do
    do_decode_txt(binary, [])
  end

  def decode_txt_strings(_), do: {:error, "invalid txt rdata"}

  defp do_decode_txt(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_decode_txt(<<len, rest::binary>>, acc) do
    if byte_size(rest) < len do
      {:error, "truncated txt chunk"}
    else
      <<chunk::binary-size(len), tail::binary>> = rest
      do_decode_txt(tail, [chunk | acc])
    end
  end

  defp do_decode_txt(_, _acc), do: {:error, "invalid txt rdata"}

  # ---- helpers ----

  defp read_fixed_header(message, offset) do
    remaining = byte_size(message) - offset

    if remaining < 10 do
      {:error, "truncated rr header at offset #{offset}"}
    else
      <<type::16, class::16, ttl::32, rdlength::16, _::binary>> =
        binary_part(message, offset, remaining)

      {:ok, type, class, ttl, rdlength}
    end
  end

  defp ensure_type(type, type), do: :ok

  defp ensure_type(actual, expected),
    do: {:error, "expected RR type #{expected}, got #{actual}"}

  def validate_u16(_field, value) when is_integer(value) and value in 0..0xFFFF,
    do: {:ok, value}

  def validate_u16(field, _value),
    do: {:error, "#{field} must be between 0 and 65535"}

  def validate_u32(_field, value) when is_integer(value) and value in 0..0xFFFFFFFF,
    do: {:ok, value}

  def validate_u32(field, _value),
    do: {:error, "#{field} must be between 0 and 4294967295"}

end
