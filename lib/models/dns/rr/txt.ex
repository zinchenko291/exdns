defmodule Models.Dns.Rr.Txt do
  @moduledoc false
  alias Models.Dns.Rr.Common

  @type t :: %__MODULE__{
          name: String.t(),
          class: non_neg_integer(),
          ttl: non_neg_integer(),
          strings: [binary()]
        }

  defstruct name: ".", class: 1, ttl: 0, strings: []

  @type_code 16

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = rr) do
    with {:ok, rdata} <- Common.encode_txt_strings(rr.strings) do
      Common.serialize_rr(rr, @type_code, rdata)
    end
  end

  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0) do
    with {:ok, header} <- Common.deserialize_rr(message, offset, @type_code),
         rdata <- binary_part(message, header.rdata_offset, header.rdlength),
         {:ok, strings} <- Common.decode_txt_strings(rdata) do
      rr = %__MODULE__{
        name: header.name,
        class: header.class,
        ttl: header.ttl,
        strings: strings
      }

      {:ok, rr, header.next_offset}
    end
  end
end
