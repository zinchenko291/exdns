defmodule Models.Dns.Rr.Soa do
  @moduledoc false
  alias Models.Dns.Name
  alias Models.Dns.Rr.Common

  @type t :: %__MODULE__{
          name: String.t(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          mname: String.t(),
          rname: String.t(),
          serial: non_neg_integer(),
          refresh: non_neg_integer(),
          retry: non_neg_integer(),
          expire: non_neg_integer(),
          minimum: non_neg_integer()
        }

  defstruct name: ".",
            class: 1,
            ttl: 0,
            mname: ".",
            rname: ".",
            serial: 0,
            refresh: 0,
            retry: 0,
            expire: 0,
            minimum: 0

  @type_code 6

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = rr) do
    with {:ok, mname_wire} <- Name.encode(rr.mname),
         {:ok, rname_wire} <- Name.encode(rr.rname),
         {:ok, serial} <- Common.validate_u32(:serial, rr.serial),
         {:ok, refresh} <- Common.validate_u32(:refresh, rr.refresh),
         {:ok, retry} <- Common.validate_u32(:retry, rr.retry),
         {:ok, expire} <- Common.validate_u32(:expire, rr.expire),
         {:ok, minimum} <- Common.validate_u32(:minimum, rr.minimum) do
      timers = <<serial::32, refresh::32, retry::32, expire::32, minimum::32>>
      rdata = mname_wire <> rname_wire <> timers
      Common.serialize_rr(rr, @type_code, rdata)
    end
  end

  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0) do
    with {:ok, header} <- Common.deserialize_rr(message, offset, @type_code),
         {:ok, rr, cursor} <- decode_rdata(message, header),
         :ok <- ensure_consumed(cursor, header) do
      {:ok, rr, header.next_offset}
    end
  end

  defp decode_rdata(message, header) do
    cursor = header.rdata_offset

    with {:ok, mname, cursor} <- Name.decode(message, cursor),
         {:ok, rname, cursor} <- Name.decode(message, cursor),
         {:ok, serial, refresh, retry, expire, minimum, cursor} <-
           decode_timers(message, cursor) do
      rr = %__MODULE__{
        name: header.name,
        class: header.class,
        ttl: header.ttl,
        mname: mname,
        rname: rname,
        serial: serial,
        refresh: refresh,
        retry: retry,
        expire: expire,
        minimum: minimum
      }

      {:ok, rr, cursor}
    end
  end

  defp decode_timers(message, cursor) do
    remaining = byte_size(message) - cursor

    if remaining < 20 do
      {:error, "soa rdata truncated"}
    else
      <<serial::32, refresh::32, retry::32, expire::32, minimum::32>> =
        binary_part(message, cursor, 20)

      {:ok, serial, refresh, retry, expire, minimum, cursor + 20}
    end
  end

  defp ensure_consumed(cursor, %{rdata_offset: start, rdlength: len}) do
    if cursor - start == len do
      :ok
    else
      {:error, "soa rdata length mismatch"}
    end
  end
end
