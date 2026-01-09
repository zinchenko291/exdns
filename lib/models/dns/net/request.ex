defmodule Models.Dns.Net.Request do
  @moduledoc """
  DNS message serializer/deserializer for requests and responses.
  Combines the Header, Question, RR sections, and Additional/OPT records.
  """

  require Logger

  alias Models.Dns.Net.{Additional, Header, Question}
  alias Models.Dns.Net.Additional.Record

  defstruct header: nil,
            question: [],
            answer: [],
            authority: [],
            additional: %Additional{}

  @type t :: %__MODULE__{
          header: Header.t(),
          question: [Question.t()],
          answer: [Record.t()],
          authority: [Record.t()],
          additional: Additional.t()
        }

  @spec deserialize(binary()) :: {:ok, t()} | {:error, String.t()}
  def deserialize(message) when is_binary(message) do
    Logger.debug("[Request] deserialize size=#{byte_size(message)}")
    if byte_size(message) < 12 do
      {:error, "dns message truncated (missing header)"}
    else
      <<header_bin::binary-size(12), _rest::binary>> = message

      with {:ok, header} <- Header.deserialize(header_bin),
           {:ok, questions, offset} <- Question.deserialize_many(message, 12, header.qdcount),
           {:ok, answers, offset} <- parse_rr_section(message, offset, header.ancount),
           {:ok, authorities, offset} <- parse_rr_section(message, offset, header.nscount),
           {:ok, additional, offset} <- Additional.deserialize(message, offset, header.arcount),
           :ok <- ensure_consumed(message, offset) do
        result =
          {:ok,
         %__MODULE__{
           header: header,
           question: questions,
           answer: answers,
           authority: authorities,
           additional: additional
         }}

        Logger.debug("[Request] deserialize ok q=#{length(questions)} a=#{length(answers)} ns=#{length(authorities)} ar=#{length(additional.records)}")
        result
      end
    end
  end

  def deserialize(_),
    do: {:error, "dns message must be a binary"}

  @spec serialize(t()) :: {:ok, binary()} | {:error, String.t()}
  def serialize(%__MODULE__{} = request) do
    Logger.debug("[Request] serialize q=#{length(request.question || [])} a=#{length(request.answer || [])}")
    with {:ok, header} <- prepare_header(request),
         {:ok, header_bin} <- Header.serialize(header),
         {:ok, question_bin} <- serialize_questions(request.question),
         {:ok, answer_bin} <- serialize_rrs(request.answer),
         {:ok, authority_bin} <- serialize_rrs(request.authority),
         {:ok, additional_bin} <- serialize_additional(request.additional) do
      payload = IO.iodata_to_binary([header_bin, question_bin, answer_bin, authority_bin, additional_bin])
      Logger.debug("[Request] serialize size=#{byte_size(payload)}")
      {:ok, payload}
    end
  end

  def serialize(_), do: {:error, "request must be a %Models.Dns.Net.Request{} struct"}

  # --- deserialization helpers

  defp parse_rr_section(message, offset, count) do
    case Additional.deserialize(message, offset, count) do
      {:ok, %Additional{opt: nil, records: records}, next} ->
        {:ok, records, next}

      {:ok, %Additional{opt: _}, _next} ->
        {:error, "unexpected OPT record outside additional section"}

      {:error, _} = err ->
        err
    end
  end

  defp ensure_consumed(message, offset) do
    if offset == byte_size(message) do
      :ok
    else
      {:error, "dns message has #{byte_size(message) - offset} trailing bytes"}
    end
  end

  # --- serialization helpers

  defp prepare_header(%__MODULE__{header: %Header{} = header} = request) do
    header =
      header
      |> Map.put(:qdcount, length(request.question || []))
      |> Map.put(:ancount, length(request.answer || []))
      |> Map.put(:nscount, length(request.authority || []))
      |> Map.put(:arcount, additional_rr_count(request.additional))

    {:ok, header}
  end

  defp prepare_header(_), do: {:error, "request.header must be a %Header{} struct"}

  defp serialize_questions(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn question, {:ok, acc} ->
      case Question.serialize(question) do
        {:ok, bin} -> {:cont, {:ok, [acc, bin]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      other -> other
    end
  end

  defp serialize_questions(_), do: {:error, "question section must be a list"}

  defp serialize_rrs(list) when is_list(list) do
    Additional.serialize(%Additional{records: list, opt: nil})
  end

  defp serialize_rrs(_), do: {:error, "rr sections must be lists"}

  defp serialize_additional(nil), do: Additional.serialize(%Additional{})
  defp serialize_additional(%Additional{} = add), do: Additional.serialize(add)
  defp serialize_additional(_), do: {:error, "additional section must be a %Additional{} struct"}

  defp additional_rr_count(%Additional{} = additional) do
    length(additional.records || []) + if additional.opt, do: 1, else: 0
  end

  defp additional_rr_count(nil), do: 0
  defp additional_rr_count(_), do: 0
end
