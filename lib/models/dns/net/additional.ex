defmodule Models.Dns.Net.Additional do
  @moduledoc """
  Parser/serializer for the DNS Additional section (RFC 1035 + EDNS extensions
  defined in RFC 6891 and DNS Cookies from RFC 7873).
  """

  require Logger
  alias Models.Dns.Name
  alias Models.Dns.Rr.Common

  import Bitwise, only: [band: 2, bor: 2, bsl: 2]

  defmodule Record do
    @moduledoc false
    @type t :: %Record{}

    @enforce_keys [:name, :type, :class, :ttl, :rdata]
    defstruct [:name, :type, :class, :ttl, :rdata]
  end

  defmodule Opt do
    @moduledoc false
    @type t :: %Opt{}

    @enforce_keys [
      :udp_payload_size,
      :extended_rcode,
      :version,
      :dnssec_ok,
      :z,
      :options
    ]
    defstruct [
      :udp_payload_size,
      :extended_rcode,
      :version,
      :dnssec_ok,
      :z,
      options: []
    ]
  end

  defmodule Opt.Option do
    @moduledoc false
    @enforce_keys [:code]
    defstruct [:code, :data, :value]
  end

  defmodule Opt.Cookie do
    @moduledoc false
    @enforce_keys [:client]
    defstruct [:client, :server]
  end

  @type t :: %__MODULE__{
          records: [Record.t()],
          opt: Opt.t() | nil
        }

  defstruct records: [], opt: nil

  @type deserialize_result :: {:ok, t(), non_neg_integer()} | {:error, String.t()}

  @type serialize_result :: {:ok, binary()} | {:error, String.t()}

  @spec deserialize(binary(), non_neg_integer(), non_neg_integer()) :: deserialize_result()
  def deserialize(message, offset, count)
      when is_binary(message) and is_integer(offset) and offset >= 0 and is_integer(count) and
             count >= 0 do
    Logger.debug("[Additional] deserialize offset=#{offset} count=#{count}")
    do_deserialize(message, offset, count, [], nil)
  end

  def deserialize(_message, offset, count),
    do: {:error, "invalid arguments for additional section #{inspect({offset, count})}"}

  defp do_deserialize(_message, offset, 0, records, opt) do
    {:ok, %__MODULE__{records: Enum.reverse(records), opt: opt}, offset}
  end

  defp do_deserialize(message, offset, count, records, opt) do
    with {:ok, rr, next_offset} <- parse_rr(message, offset),
         {:ok, {records, opt}} <- handle_rr(rr, records, opt) do
      do_deserialize(message, next_offset, count - 1, records, opt)
    end
  end

  defp handle_rr(%{type: 41} = rr, records, nil) do
    with {:ok, opt_rr} <- parse_opt(rr) do
      {:ok, {records, opt_rr}}
    end
  end

  defp handle_rr(%{type: 41}, _records, _opt),
    do: {:error, "multiple OPT records in additional section"}

  defp handle_rr(rr, records, opt) do
    record = %Record{
      name: rr.name,
      type: rr.type,
      class: rr.class,
      ttl: rr.ttl,
      rdata: rr.rdata
    }

    {:ok, {[record | records], opt}}
  end

  @spec serialize(t()) :: serialize_result()
  def serialize(%__MODULE__{} = additional) do
    Logger.debug("[Additional] serialize records=#{length(additional.records)} opt=#{additional.opt != nil}")
    with {:ok, records_bin} <- serialize_records(additional.records),
         {:ok, opt_bin} <- serialize_opt(additional.opt) do
      {:ok, IO.iodata_to_binary([records_bin, opt_bin])}
    end
  end

  def serialize(_), do: {:error, "additional section must be a struct"}

  # -- parsing helpers

  defp parse_rr(message, offset) do
    with {:ok, name, cursor} <- Name.decode(message, offset),
         {:ok, type, class, ttl, rdlength} <- read_rr_header(message, cursor),
         data_offset <- cursor + 10,
         data_end <- data_offset + rdlength,
         true <- data_end <= byte_size(message) do
      rdata = binary_part(message, data_offset, rdlength)

      {:ok,
       %{
         name: name,
         type: type,
         class: class,
         ttl: ttl,
         rdlength: rdlength,
         rdata: rdata
       }, data_end}
    else
      false -> {:error, "rr data truncated at offset #{offset}"}
      {:error, _} = err -> err
    end
  end

  defp read_rr_header(message, offset) do
    remaining = byte_size(message) - offset

    if remaining < 10 do
      {:error, "rr header truncated at offset #{offset}"}
    else
      <<type::16, class::16, ttl::32, rdlength::16, _rest::binary>> =
        binary_part(message, offset, remaining)

      {:ok, type, class, ttl, rdlength}
    end
  end

  defp parse_opt(%{name: ".", class: udp_payload, ttl: ttl, rdata: rdata}) do
    <<extended_rcode::8, version::8, flags::16>> = <<ttl::32>>
    dnssec_ok = band(flags, 0x8000) == 0x8000
    z = band(flags, 0x7FFF)

    with {:ok, options} <- parse_opt_options(rdata, []) do
      {:ok,
       %Opt{
         udp_payload_size: udp_payload,
         extended_rcode: extended_rcode,
         version: version,
         dnssec_ok: dnssec_ok,
         z: z,
         options: options
       }}
    end
  end

  defp parse_opt(_rr), do: {:error, "invalid OPT resource record"}

  defp parse_opt_options(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_opt_options(<<code::16, len::16, rest::binary>>, acc) do
    if byte_size(rest) < len do
      {:error, "edns option #{code} truncated"}
    else
      <<data::binary-size(len), tail::binary>> = rest

      with {:ok, parsed} <- parse_option_value(code, data) do
        option = %Opt.Option{code: code, data: data, value: parsed}
        parse_opt_options(tail, [option | acc])
      end
    end
  end

  defp parse_option_value(10, data) do
    if byte_size(data) < 8 do
      {:error, "dns cookie option must be at least 8 bytes"}
    else
      <<client::binary-size(8), rest::binary>> = data

      cond do
        byte_size(rest) == 0 ->
          {:ok, %Opt.Cookie{client: client, server: nil}}

        byte_size(rest) in 8..32 ->
          {:ok, %Opt.Cookie{client: client, server: rest}}

        true ->
          {:error, "server cookie must be between 8 and 32 bytes"}
      end
    end
  end

  defp parse_option_value(_code, _data), do: {:ok, nil}

  # -- serialization helpers

  defp serialize_records(records) when is_list(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case serialize_record(record) do
        {:ok, bin} -> {:cont, {:ok, [acc, bin]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      other -> other
    end
  end

  defp serialize_records(_), do: {:error, "records must be a list"}

  defp serialize_record(%Record{name: name, type: type, class: class, ttl: ttl, rdata: rdata})
       when is_binary(rdata) do
    with {:ok, name_wire} <- Name.encode(name),
         {:ok, type} <- Common.validate_u16(:type, type),
         {:ok, class} <- Common.validate_u16(:class, class),
         {:ok, ttl} <- Common.validate_u32(:ttl, ttl),
         {:ok, rdlength} <- Common.validate_u16(:rdlength, byte_size(rdata)) do
      {:ok,
       IO.iodata_to_binary([
         name_wire,
         <<type::16, class::16, ttl::32, rdlength::16>>,
         rdata
       ])}
    end
  end

  defp serialize_record(%Record{}), do: {:error, "record rdata must be a binary"}
  defp serialize_record(_), do: {:error, "record must be a %Record{} struct"}

  defp serialize_opt(nil), do: {:ok, <<>>}

  defp serialize_opt(%Opt{} = opt) do
    with {:ok, udp_payload} <- Common.validate_u16(:udp_payload_size, opt.udp_payload_size),
         :ok <- ensure_byte(:extended_rcode, opt.extended_rcode),
         :ok <- ensure_byte(:version, opt.version),
         {:ok, z} <- validate_z(opt.z),
         {:ok, options_bin} <- serialize_opt_options(opt.options) do
      flags = encode_flags(opt.dnssec_ok, z)
      ttl = bor(bor(bsl(opt.extended_rcode, 24), bsl(opt.version, 16)), flags)
      rdlength = byte_size(options_bin)

      if rdlength > 0xFFFF do
        {:error, "total edns options exceed 65535 bytes"}
      else
        {:ok,
         IO.iodata_to_binary([
           <<0>>,
           <<41::16, udp_payload::16, ttl::32, rdlength::16>>,
           options_bin
         ])}
      end
    end
  end

  defp serialize_opt(_), do: {:error, "opt must be nil or %Opt{}"}

  defp serialize_opt_options(options) when is_list(options) do
    Enum.reduce_while(options, {:ok, []}, fn option, {:ok, acc} ->
      case serialize_opt_option(option) do
        {:ok, bin} -> {:cont, {:ok, [acc, bin]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      other -> other
    end
  end

  defp serialize_opt_options(_), do: {:error, "options must be a list"}

  defp serialize_opt_option(%Opt.Option{code: code} = option) do
    with {:ok, code} <- Common.validate_u16(:option_code, code),
         {:ok, data} <- option_data(option),
         {:ok, len} <- Common.validate_u16(:option_length, byte_size(data)) do
      {:ok, IO.iodata_to_binary([<<code::16, len::16>>, data])}
    end
  end

  defp serialize_opt_option(_), do: {:error, "option must be a %Opt.Option{}"}

  defp option_data(%Opt.Option{value: %Opt.Cookie{} = cookie}),
    do: encode_cookie(cookie)

  defp option_data(%Opt.Option{data: data}) when is_binary(data), do: {:ok, data}
  defp option_data(_), do: {:error, "option requires binary data or a known value"}

  defp encode_cookie(%Opt.Cookie{client: client, server: server}) when is_binary(client) do
    if byte_size(client) != 8 do
      {:error, "client cookie must be exactly 8 bytes"}
    else
      cond do
        is_nil(server) ->
          {:ok, client}

        is_binary(server) and byte_size(server) in 8..32 ->
          {:ok, client <> server}

        true ->
          {:error, "server cookie must be between 8 and 32 bytes"}
      end
    end
  end

  defp encode_cookie(_), do: {:error, "cookie requires binary client value"}

  # -- misc helpers

  defp ensure_byte(_field, value) when is_integer(value) and value in 0..0xFF, do: :ok
  defp ensure_byte(field, _), do: {:error, "#{field} must be between 0 and 255"}

  defp validate_z(value) when is_integer(value) and value in 0..0x7FFF, do: {:ok, value}
  defp validate_z(_), do: {:error, "z flag bits must be between 0 and 32767"}

  defp encode_flags(dnssec_ok, z) do
    base = band(z, 0x7FFF)

    if dnssec_ok do
      bor(0x8000, base)
    else
      base
    end
  end
end
