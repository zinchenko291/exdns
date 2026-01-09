defmodule Models.Dns.Net.Question do
  @moduledoc """
  DNS Question section parser (QNAME, QTYPE, QCLASS).
  Supports RFC1035 name compression pointers.
  """

  require Logger
  alias __MODULE__
  alias Models.Dns.Name

  defstruct [:qname, :qtype, :qclass]

  @type t :: %Question{
          qname: String.t(),
          qtype: non_neg_integer(),
          qclass: non_neg_integer()
        }

  @doc """
  Parse one Question from full DNS `message` starting at byte `offset`.

  Returns:
    - {:ok, %Question{}, next_offset}
    - {:error, reason}
  """
  @spec deserialize(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def deserialize(message, offset \\ 0)
      when is_binary(message) and is_integer(offset) and offset >= 0 do
    Logger.debug("[Question] deserialize offset=#{offset}")
    with {:ok, qname, offset1} <- Name.decode(message, offset),
         {:ok, qtype, qclass, offset2} <- parse_qtype_qclass(message, offset1),
         :ok <- validate_question(%Question{qname: qname, qtype: qtype, qclass: qclass}) do
      Logger.debug("[Question] deserialize qname=#{qname} qtype=#{qtype} qclass=#{qclass}")
      {:ok, %Question{qname: qname, qtype: qtype, qclass: qclass}, offset2}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Serialize a question struct into DNS wire format.
  """
  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%Question{} = question) do
    Logger.debug("[Question] serialize qname=#{question.qname} qtype=#{question.qtype}")
    with :ok <- validate_question(question),
         {:ok, qname_wire} <- Name.encode(question.qname) do
      {:ok, qname_wire <> <<question.qtype::16, question.qclass::16>>}
    end
  end

  @doc """
  Parse `count` questions starting at `offset`.

  Returns:
    - {:ok, [question], next_offset}
    - {:error, reason}
  """
  @spec deserialize_many(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [t()], non_neg_integer()} | {:error, String.t()}
  def deserialize_many(message, offset, count)
      when is_binary(message) and is_integer(offset) and offset >= 0 and is_integer(count) and
             count >= 0 do
    do_deserialize_many(message, offset, count, [])
  end

  defp do_deserialize_many(_message, offset, 0, acc), do: {:ok, Enum.reverse(acc), offset}

  defp do_deserialize_many(message, offset, count, acc) do
    case deserialize(message, offset) do
      {:ok, q, next_offset} -> do_deserialize_many(message, next_offset, count - 1, [q | acc])
      {:error, _} = err -> err
    end
  end

  # ----------------------------
  # QTYPE/QCLASS
  # ----------------------------

  defp parse_qtype_qclass(message, offset) do
    if byte_size(message) < offset + 4 do
      {:error, "not enough bytes for QTYPE/QCLASS at offset #{offset}"}
    else
      <<_::binary-size(offset), qtype::16, qclass::16, _::binary>> = message
      {:ok, qtype, qclass, offset + 4}
    end
  end

  # ----------------------------
  # Validation
  # ----------------------------

  defp validate_question(%Question{qname: qname, qtype: qtype, qclass: qclass}) do
    with :ok <- validate_qname(qname),
         :ok <- validate_qtype(qtype) do
      validate_qclass(qclass)
    end
  end

  defp validate_qname(qname) when not is_binary(qname), do: {:error, "qname must be a string"}

  defp validate_qname(qname) do
    cond do
      byte_size(qname) > 255 ->
        {:error, "qname too long"}

      qname != "." and Enum.any?(String.split(qname, ".", trim: true), &(byte_size(&1) > 63)) ->
        {:error, "each label in qname must be <= 63 bytes"}

      true ->
        :ok
    end
  end

  defp validate_qtype(qtype) when is_integer(qtype) and qtype >= 0 and qtype <= 0xFFFF, do: :ok
  defp validate_qtype(_), do: {:error, "qtype must be between 0 and 65535"}

  defp validate_qclass(qclass) when is_integer(qclass) and qclass >= 0 and qclass <= 0xFFFF,
    do: :ok

  defp validate_qclass(_), do: {:error, "qclass must be between 0 and 65535"}
end
