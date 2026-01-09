defmodule Models.Dns.Rr.Mx do
  @moduledoc false
  alias Models.Dns.Name
  alias Models.Dns.Rr.Common

  @type t :: %__MODULE__{
          name: String.t(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          preference: non_neg_integer(),
          exchange: String.t()
        }

  defstruct name: ".", class: 1, ttl: 0, preference: 0, exchange: "."

  @type_code 15

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = rr) do
    with {:ok, pref} <- Common.validate_u16(:preference, rr.preference),
         {:ok, exchange_wire} <- Name.encode(rr.exchange) do
      rdata = <<pref::16>> <> exchange_wire
      Common.serialize_rr(rr, @type_code, rdata)
    end
  end

  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0) do
    with {:ok, header} <- Common.deserialize_rr(message, offset, @type_code),
         {:ok, preference, exchange, cursor} <- decode_rdata(message, header),
         :ok <- ensure_consumed(cursor, header) do
      rr = %__MODULE__{
        name: header.name,
        class: header.class,
        ttl: header.ttl,
        preference: preference,
        exchange: exchange
      }

      {:ok, rr, header.next_offset}
    end
  end

  defp decode_rdata(message, %{rdata_offset: offset, rdlength: len}) do
    if len < 2 do
      {:error, "mx rdata truncated"}
    else
      <<pref::16>> = binary_part(message, offset, 2)
      exchange_offset = offset + 2

      case Name.decode(message, exchange_offset) do
        {:ok, exchange, cursor} -> {:ok, pref, exchange, cursor}
        {:error, _} = err -> err
      end
    end
  end

  defp ensure_consumed(cursor, %{rdata_offset: start, rdlength: len}) do
    if cursor - start == len do
      :ok
    else
      {:error, "mx rdata length mismatch"}
    end
  end
end
