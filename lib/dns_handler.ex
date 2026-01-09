defmodule DnsHandler do
  @moduledoc false
  require Logger

  use Task

  alias Models.Dns.Name
  alias Models.Dns.Net.Additional
  alias Models.Dns.Net.Additional.Record
  alias Models.Dns.Net.Request
  alias Models.Dns.Rr.Common
  alias Models.Dns.Rr.Types
  alias Models.Dns.Zone

  def start_task(args) do
    Task.Supervisor.start_child(__MODULE__, fn -> handle_request(args) end)
  end

  def handle_request({:udp, handle_socket, peer_ip, peer_port, packet}) do
    Logger.info("[DnsHandler] request from #{inspect(peer_ip)}:#{peer_port}")
    Logger.debug("[DnsHandler] request size=#{byte_size(packet)}")
    case Request.deserialize(packet) do
      {:ok, request} ->
        Logger.debug("[DnsHandler] parsed questions=#{length(request.question)}")
        response = build_response(request)

        case Request.serialize(response) do
          {:ok, binary} ->
            Logger.info("[DnsHandler] sending response size=#{byte_size(binary)}")
            :ok = :gen_udp.send(handle_socket, peer_ip, peer_port, binary)

          {:error, reason} ->
            Logger.warning("[DnsHandler] failed to serialize response: #{reason}")
        end

      {:error, reason} ->
        Logger.warning("[DnsHandler] failed to parse request: #{reason}")
    end
  end

  defp build_response(%Request{} = request) do
    questions = request.question
    {rcode, answers} = resolve_answers(questions)
    Logger.debug("[DnsHandler] response answers=#{length(answers)} rcode=#{rcode}")

    header =
      request.header
      |> Map.put(:qr, 1)
      |> Map.put(:aa, 1)
      |> Map.put(:tc, 0)
      |> Map.put(:ra, 0)
      |> Map.put(:rcode, rcode)

    %Request{
      header: header,
      question: questions,
      answer: answers,
      authority: [],
      additional: %Additional{records: [], opt: request.additional.opt}
    }
  end

  defp resolve_answers([]), do: {0, []}

  defp resolve_answers(questions) do
    {answers, missing} =
      Enum.reduce(questions, {[], 0}, fn question, {acc, missing} ->
        qname = normalize_name(question.qname)
        qtype = question.qtype

        case find_zone(qname) do
          {:ok, zone_name, data} ->
            records = zone_records(zone_name, data, qname, qtype)
            {[records | acc], missing}

          :not_found ->
            {acc, missing + 1}
        end
      end)

    answer_list = answers |> Enum.reverse() |> List.flatten()

    rcode = if missing == length(questions), do: 3, else: 0
    Logger.debug("[DnsHandler] resolve missing=#{missing} total=#{length(questions)}")
    {rcode, answer_list}
  end

  defp find_zone(domain) do
    labels = String.split(domain, ".", trim: true)

    labels
    |> suffixes()
    |> Enum.reduce_while(:not_found, fn candidate, _acc ->
      case Zone.fetch(candidate) do
        {:ok, data} -> {:halt, {:ok, candidate, data}}
        :not_found -> {:cont, :not_found}
        {:error, _} -> {:cont, :not_found}
      end
    end)
  end

  defp suffixes(labels) do
    0..(length(labels) - 1)
    |> Enum.map(fn index -> labels |> Enum.drop(index) |> Enum.join(".") end)
  end

  defp zone_records(zone_name, data, qname, qtype) when is_map(data) do
    records = Map.get(data, "records", [])
    ttl_default = Map.get(data, "ttl", 60)

    records
    |> Enum.filter(&match_record?(&1, zone_name, qname, qtype))
    |> Enum.flat_map(&build_record(&1, zone_name, ttl_default))
  end

  defp zone_records(_zone_name, _data, _qname, _qtype), do: []

  defp match_record?(record, zone_name, qname, qtype) when is_map(record) do
    name = record_name(record, zone_name)
    type = record_type(record)

    name == qname and (qtype == 255 or type == qtype)
  end

  defp match_record?(_record, _zone_name, _qname, _qtype), do: false

  defp build_record(record, zone_name, ttl_default) do
    name = record_name(record, zone_name)
    type = record_type(record)
    class = record_class(record)
    ttl = record_ttl(record, ttl_default)

    rdata_list = encode_rdata(type, record)

    Enum.map(rdata_list, fn rdata ->
      %Record{
        name: name,
        type: type,
        class: class,
        ttl: ttl,
        rdata: rdata
      }
    end)
  end

  defp record_name(record, zone_name) do
    raw =
      record
      |> Map.get("name", "@")
      |> normalize_name()

    cond do
      raw in ["@", ""] -> zone_name
      String.contains?(raw, ".") -> raw
      true -> "#{raw}.#{zone_name}"
    end
  end

  defp record_type(%{"type" => type}) do
    case Types.code(type) do
      {:ok, code} -> code
      {:error, _} -> 0
    end
  end

  defp record_type(_), do: 0

  defp record_class(%{"class" => class}) when is_integer(class), do: class
  defp record_class(%{"class" => "IN"}), do: 1
  defp record_class(_), do: 1

  defp record_ttl(%{"ttl" => ttl}, _default) when is_integer(ttl), do: ttl
  defp record_ttl(_record, default), do: default

  defp encode_rdata(1, %{"data" => data}), do: encode_ipv4(data)
  defp encode_rdata(28, %{"data" => data}), do: encode_ipv6(data)
  defp encode_rdata(2, %{"data" => data}), do: encode_name_rdata(data)
  defp encode_rdata(5, %{"data" => data}), do: encode_name_rdata(data)
  defp encode_rdata(12, %{"data" => data}), do: encode_name_rdata(data)
  defp encode_rdata(16, %{"data" => data}), do: encode_txt_rdata(data)
  defp encode_rdata(15, %{"data" => data}), do: encode_mx_rdata(data)
  defp encode_rdata(6, %{"data" => data}), do: encode_soa_rdata(data)
  defp encode_rdata(_, _), do: []

  defp encode_ipv4(data) when is_binary(data), do: encode_ipv4([data])

  defp encode_ipv4(list) when is_list(list) do
    encode_ip_list(list, 4, &Common.encode_ipv4/1)
  end

  defp encode_ipv4(_), do: []

  defp encode_ipv6(data) when is_binary(data), do: encode_ipv6([data])

  defp encode_ipv6(list) when is_list(list) do
    encode_ip_list(list, 8, &Common.encode_ipv6/1)
  end

  defp encode_ipv6(_), do: []

  defp encode_ip_list(list, tuple_size, encoder) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn ip ->
      parse_ip(ip, tuple_size, encoder)
    end)
  end

  defp parse_ip(ip, tuple_size, encoder) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} when tuple_size(tuple) == tuple_size ->
        case encoder.(tuple) do
          {:ok, rdata} -> [rdata]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp encode_name_rdata(data) when is_binary(data), do: encode_name_rdata([data])

  defp encode_name_rdata(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn name ->
      case Name.encode(normalize_name(name)) do
        {:ok, rdata} -> [rdata]
        _ -> []
      end
    end)
  end

  defp encode_name_rdata(_), do: []

  defp encode_txt_rdata(data) when is_binary(data), do: encode_txt_rdata([data])

  defp encode_txt_rdata(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Common.encode_txt_strings()
    |> case do
      {:ok, rdata} -> [rdata]
      _ -> []
    end
  end

  defp encode_txt_rdata(_), do: []

  defp encode_mx_rdata(%{"preference" => pref, "exchange" => exchange})
       when is_integer(pref) and is_binary(exchange) do
    with {:ok, pref} <- Common.validate_u16(:preference, pref),
         {:ok, exchange_wire} <- Name.encode(normalize_name(exchange)) do
      [<<pref::16>> <> exchange_wire]
    else
      _ -> []
    end
  end

  defp encode_mx_rdata(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&encode_mx_rdata/1)
  end

  defp encode_mx_rdata(_), do: []

  defp encode_soa_rdata(%{
         "mname" => mname,
         "rname" => rname,
         "serial" => serial,
         "refresh" => refresh,
         "retry" => retry,
         "expire" => expire,
         "minimum" => minimum
       })
       when is_binary(mname) and is_binary(rname) and is_integer(serial) and is_integer(refresh) and
              is_integer(retry) and is_integer(expire) and is_integer(minimum) do
    with {:ok, mname_wire} <- Name.encode(normalize_name(mname)),
         {:ok, rname_wire} <- Name.encode(normalize_name(rname)),
         {:ok, serial} <- Common.validate_u32(:serial, serial),
         {:ok, refresh} <- Common.validate_u32(:refresh, refresh),
         {:ok, retry} <- Common.validate_u32(:retry, retry),
         {:ok, expire} <- Common.validate_u32(:expire, expire),
         {:ok, minimum} <- Common.validate_u32(:minimum, minimum) do
      timers = <<serial::32, refresh::32, retry::32, expire::32, minimum::32>>
      [mname_wire <> rname_wire <> timers]
    else
      _ -> []
    end
  end

  defp encode_soa_rdata(_), do: []

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_name(_), do: ""

end
