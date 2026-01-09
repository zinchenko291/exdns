defmodule Models.Dns.Rr.Aaaa do
  @moduledoc false
  alias Models.Dns.Rr.Common

  @type t :: %__MODULE__{
          name: String.t(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          address: :inet.ip6_address()
        }

  defstruct name: ".", class: 1, ttl: 0, address: {0, 0, 0, 0, 0, 0, 0, 0}

  @type_code 28

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = rr) do
    with {:ok, rdata} <- Common.encode_ipv6(rr.address) do
      Common.serialize_rr(rr, @type_code, rdata)
    end
  end

  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0) do
    with {:ok, header} <- Common.deserialize_rr(message, offset, @type_code),
         {:ok, address} <-
           message
           |> binary_part(header.rdata_offset, header.rdlength)
           |> Common.decode_ipv6() do
      rr = %__MODULE__{
        name: header.name,
        class: header.class,
        ttl: header.ttl,
        address: address
      }

      {:ok, rr, header.next_offset}
    end
  end
end
