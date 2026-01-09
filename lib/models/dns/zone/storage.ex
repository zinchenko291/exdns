defmodule Models.Dns.Zone.Storage do
  @moduledoc false

  require Logger

  alias Models.Dns.Rr.Types

  @spec path_for(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def path_for(domain) when is_binary(domain) and byte_size(domain) > 0 do
    folder =
      :exdns
      |> Application.fetch_env!(:zones_folder)
      |> Path.expand(File.cwd!())

    hash = domain_md5(domain)
    shard1 = String.slice(hash, 0, 2)
    shard2 = String.slice(hash, 2, 2)
    filename = "#{domain}.json"

    {:ok, Path.join([folder, shard1, shard2, filename])}
  end

  def path_for(_), do: {:error, "domain must be a non-empty string"}

  @spec read(String.t()) :: {:ok, map()} | :not_found | {:error, String.t()}
  def read(domain) do
    Logger.debug("[Zone.Storage] read #{domain}")
    with {:ok, path} <- path_for(domain) do
      case File.read(path) do
        {:ok, content} ->
          with {:ok, data} <- decode(content),
               :ok <- validate_zone(data) do
            Logger.debug("[Zone.Storage] read ok #{domain}")
            {:ok, data}
          end

        {:error, :enoent} ->
          Logger.debug("[Zone.Storage] missing #{domain}")
          :not_found

        {:error, reason} ->
          Logger.warning("[Zone.Storage] read failed #{domain}: #{inspect(reason)}")
          {:error, "failed to read zone file: #{inspect(reason)}"}
      end
    end
  end

  @spec write(String.t(), map()) :: :ok | {:error, String.t()}
  def write(domain, data) when is_map(data) do
    write_atomic(domain, data)
  end

  def write(_domain, _data), do: {:error, "zone data must be a map"}

  @spec delete(String.t()) :: :ok | :not_found | {:error, String.t()}
  def delete(domain) do
    Logger.debug("[Zone.Storage] delete #{domain}")
    with {:ok, path} <- path_for(domain) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :not_found
        {:error, reason} -> {:error, "failed to delete zone file: #{inspect(reason)}"}
      end
    end
  end

  @spec write_atomic(String.t(), map()) :: :ok | {:error, String.t()}
  def write_atomic(domain, data) when is_map(data) do
    Logger.debug("[Zone.Storage] write #{domain}")
    with :ok <- validate_zone(data),
         {:ok, path} <- path_for(domain),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(data),
         :ok <- write_temp(path, json) do
      replace_file(path)
    end
  end

  def write_atomic(_domain, _data), do: {:error, "zone data must be a map"}

  @spec validate_zone(map()) :: :ok | {:error, String.t()}
  def validate_zone(data) when is_map(data) do
    with :ok <- validate_version(data),
         {:ok, records} <- fetch_records(data) do
      validate_records(records)
    end
  end

  def validate_zone(_), do: {:error, "zone json must be an object"}

  @spec exists?(String.t()) :: {:ok, boolean()} | {:error, String.t()}
  def exists?(domain) do
    with {:ok, path} <- path_for(domain) do
      {:ok, File.exists?(path)}
    end
  end

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "failed to encode json: #{inspect(reason)}"}
    end
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, "zone json must be an object"}
      {:error, reason} -> {:error, "failed to decode json: #{inspect(reason)}"}
    end
  end

  defp validate_version(data) do
    case Map.get(data, "version") do
      nil -> :ok
      v when is_integer(v) and v >= 1 -> :ok
      _ -> {:error, "version must be an integer >= 1"}
    end
  end

  defp fetch_records(data) do
    case Map.fetch(data, "records") do
      {:ok, records} when is_list(records) -> {:ok, records}
      {:ok, _} -> {:error, "records must be a list"}
      :error -> {:error, "records is required"}
    end
  end

  defp validate_records(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {record, idx}, _acc ->
      case validate_record(record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "record #{idx}: #{reason}"}}
      end
    end)
  end

  defp validate_record(record) when is_map(record) do
    with :ok <- validate_name(Map.get(record, "name")),
         {:ok, type} <- normalize_type(Map.get(record, "type")),
         :ok <- validate_class(Map.get(record, "class")),
         :ok <- validate_ttl(Map.get(record, "ttl")) do
      validate_data(type, Map.get(record, "data"))
    end
  end

  defp validate_record(_), do: {:error, "record must be an object"}

  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(_), do: {:error, "name must be a non-empty string"}

  defp validate_class(nil), do: :ok
  defp validate_class(class) when is_integer(class) and class in 0..0xFFFF, do: :ok
  defp validate_class("IN"), do: :ok
  defp validate_class(_), do: {:error, "class must be IN or 0..65535"}

  defp validate_ttl(nil), do: :ok
  defp validate_ttl(ttl) when is_integer(ttl) and ttl >= 0, do: :ok
  defp validate_ttl(_), do: {:error, "ttl must be a non-negative integer"}

  defp normalize_type(type) do
    Types.code(type)
  end

  defp validate_data(1, data), do: validate_strings(data)
  defp validate_data(28, data), do: validate_strings(data)
  defp validate_data(2, data), do: validate_strings(data)
  defp validate_data(5, data), do: validate_strings(data)
  defp validate_data(12, data), do: validate_strings(data)
  defp validate_data(16, data), do: validate_strings(data)
  defp validate_data(15, data), do: validate_mx_data(data)
  defp validate_data(6, data), do: validate_soa_data(data)
  defp validate_data(_, _), do: {:error, "unsupported record type"}

  defp validate_strings(data) when is_binary(data) and byte_size(data) > 0, do: :ok

  defp validate_strings(data) when is_list(data) do
    if Enum.all?(data, &(is_binary(&1) and byte_size(&1) > 0)) do
      :ok
    else
      {:error, "data must be a list of non-empty strings"}
    end
  end

  defp validate_strings(_), do: {:error, "data must be a non-empty string or list"}

  defp validate_mx_data(%{"preference" => pref, "exchange" => exch})
       when is_integer(pref) and pref in 0..0xFFFF and is_binary(exch) and byte_size(exch) > 0,
       do: :ok

  defp validate_mx_data(list) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      validate_mx_list(list)
    else
      {:error, "mx data must be an object or list of objects"}
    end
  end

  defp validate_mx_data(_), do: {:error, "mx data must be an object or list of objects"}

  defp validate_mx_list(list) do
    list
    |> Enum.reduce_while(:ok, fn item, _acc ->
      case validate_mx_data(item) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_soa_data(%{
         "mname" => mname,
         "rname" => rname,
         "serial" => serial,
         "refresh" => refresh,
         "retry" => retry,
         "expire" => expire,
         "minimum" => minimum
       })
       when is_binary(mname) and is_binary(rname) and is_integer(serial) and is_integer(refresh) and
              is_integer(retry) and is_integer(expire) and is_integer(minimum),
       do: :ok

  defp validate_soa_data(_), do: {:error, "soa data must include mname/rname/serial/refresh/retry/expire/minimum"}

  defp write_temp(path, json) do
    tmp_path = path <> ".tmp"

    case File.write(tmp_path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to write zone temp file: #{inspect(reason)}"}
    end
  end

  defp replace_file(path) do
    tmp_path = path <> ".tmp"

    case File.rename(tmp_path, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.rm(path) do
          :ok ->
            File.rename(tmp_path, path)

          {:error, reason} ->
            {:error, "failed to replace zone file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed to replace zone file: #{inspect(reason)}"}
    end
  end

  defp domain_md5(domain) do
    :crypto.hash(:md5, domain)
    |> Base.encode16(case: :lower)
  end
end
