defmodule Models.Dns.Name do
  @moduledoc """
  Helpers for working with DNS domain names (QNAMEs).
  Provides encoding to the wire format as well as decoding with
  support for RFC1035 name compression pointers.
  """

  require Logger
  import Bitwise, only: [band: 2, bor: 2, bsl: 2]

  @max_jumps 50

  @type t :: String.t()

  @doc """
  Encode a domain `name` to its DNS wire representation.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, String.t()}
  def encode("."), do: {:ok, <<0>>}

  def encode(name) when is_binary(name) do
    Logger.debug("[Name] encode name=#{name}")
    trimmed = String.trim_trailing(name, ".")
    labels = trimmed |> String.split(".", trim: true)

    cond do
      byte_size(trimmed) > 0 and labels == [] ->
        {:error, "invalid name #{inspect(name)}"}

      byte_size(name) > 255 ->
        {:error, "name #{inspect(name)} is longer than 255 bytes"}

      Enum.any?(labels, &(byte_size(&1) > 63)) ->
        {:error, "each label must be at most 63 bytes"}

      true ->
        encoded =
          labels
          |> Enum.map(fn label ->
            <<byte_size(label)>> <> label
          end)
          |> IO.iodata_to_binary()

        {:ok, encoded <> <<0>>}
    end
  end

  def encode(_name), do: {:error, "name must be a string"}

  @doc """
  Decode a domain name from `message` starting at `offset`.
  Returns `{:ok, name, next_offset}` on success.
  """
  @spec decode(binary(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer()} | {:error, String.t()}
  def decode(message, offset \\ 0)

  def decode(message, offset) when is_binary(message) and is_integer(offset) and offset >= 0 do
    Logger.debug("[Name] decode offset=#{offset}")
    with {:ok, labels, next} <- parse_labels(message, offset, MapSet.new([offset]), 0) do
      {:ok, labels_to_name(labels), next}
    end
  end

  def decode(_message, offset),
    do: {:error, "invalid arguments when decoding name at offset #{inspect(offset)}"}

  defp labels_to_name([]), do: "."
  defp labels_to_name(labels), do: Enum.join(labels, ".")

  defp parse_labels(message, offset, visited, jumps) do
    with :ok <- check_jumps(jumps),
         :ok <- check_bounds(message, offset) do
      b = :binary.at(message, offset)
      parse_label_type(b, message, offset, visited, jumps)
    end
  end

  defp check_jumps(jumps) when jumps > @max_jumps,
    do: {:error, "too many compression jumps when parsing name"}

  defp check_jumps(_), do: :ok

  defp check_bounds(message, offset) do
    if offset >= byte_size(message) do
      {:error, "offset #{offset} is outside the DNS message"}
    else
      :ok
    end
  end

  defp parse_label_type(0, _message, offset, _visited, _jumps), do: {:ok, [], offset + 1}

  defp parse_label_type(b, message, offset, visited, jumps)
       when band(b, 0b1100_0000) == 0b1100_0000 do
    parse_pointer(message, offset, visited, jumps, b)
  end

  defp parse_label_type(b, message, offset, visited, jumps) when b <= 63 do
    parse_label(message, offset, visited, jumps, b)
  end

  defp parse_label_type(b, _message, offset, _visited, _jumps),
    do: {:error, "invalid label length byte #{b} at offset #{offset}"}

  defp parse_pointer(message, offset, visited, jumps, b) do
    if offset + 1 >= byte_size(message) do
      {:error, "truncated compression pointer at offset #{offset}"}
    else
      b2 = :binary.at(message, offset + 1)
      ptr = bor(bsl(band(b, 0b0011_1111), 8), b2)

      cond do
        MapSet.member?(visited, ptr) ->
          {:error, "compression pointer loop detected"}

        ptr >= byte_size(message) ->
          {:error, "compression pointer #{ptr} outside message"}

        true ->
          new_visited = MapSet.put(visited, ptr)

          with {:ok, labels, _ignored} <- parse_labels(message, ptr, new_visited, jumps + 1) do
            {:ok, labels, offset + 2}
          end
      end
    end
  end

  defp parse_label(message, offset, visited, jumps, label_len) do
    label_start = offset + 1
    label_end = label_start + label_len

    if label_end > byte_size(message) do
      {:error, "truncated label at offset #{offset}"}
    else
      label = binary_part(message, label_start, label_len)

      with {:ok, rest, next_offset} <- parse_labels(message, label_end, visited, jumps) do
        {:ok, [label | rest], next_offset}
      end
    end
  end
end
