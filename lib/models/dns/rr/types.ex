defmodule Models.Dns.Rr.Types do
  @moduledoc false

  @type_map %{
    "A" => 1,
    "NS" => 2,
    "CNAME" => 5,
    "SOA" => 6,
    "PTR" => 12,
    "MX" => 15,
    "TXT" => 16,
    "AAAA" => 28
  }

  @spec code(String.t() | non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def code(type) when is_integer(type) and type in 0..0xFFFF, do: {:ok, type}
  def code(type) when is_integer(type), do: {:error, "type must be between 0 and 65535"}

  def code(type) when is_binary(type) do
    case Map.fetch(@type_map, String.upcase(type)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "unsupported record type #{inspect(type)}"}
    end
  end

  def code(nil), do: {:error, "type is required"}
  def code(_), do: {:error, "type is required"}
end
