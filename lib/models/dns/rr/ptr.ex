defmodule Models.Dns.Rr.Ptr do
  @moduledoc false
  alias Models.Dns.Name
  alias Models.Dns.Rr.Common

  @type t :: %__MODULE__{
          name: String.t(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          ptrdname: String.t()
        }

  defstruct name: ".", class: 1, ttl: 0, ptrdname: "."

  @type_code 12

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = rr) do
    with {:ok, ptr_wire} <- Name.encode(rr.ptrdname) do
      Common.serialize_rr(rr, @type_code, ptr_wire)
    end
  end

  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0) do
    with {:ok, header} <- Common.deserialize_rr(message, offset, @type_code),
         {:ok, ptrdname, cursor} <- Name.decode(message, header.rdata_offset),
         :ok <- ensure_consumed(cursor, header) do
      rr = %__MODULE__{
        name: header.name,
        class: header.class,
        ttl: header.ttl,
        ptrdname: ptrdname
      }

      {:ok, rr, header.next_offset}
    end
  end

  defp ensure_consumed(cursor, %{rdata_offset: start, rdlength: len}) do
    if cursor - start == len do
      :ok
    else
      {:error, "ptr rdata length mismatch"}
    end
  end
end
