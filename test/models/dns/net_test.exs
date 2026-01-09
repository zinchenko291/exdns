defmodule Models.Dns.NetTest do
  use ExUnit.Case, async: true

  alias Models.Dns.Net.{Header, Question}

  test "Header serialize/deserialize roundtrip" do
    header = %Header{
      id: 0x1234,
      qr: 0,
      opcode: 0,
      aa: 0,
      tc: 0,
      rd: 1,
      ra: 1,
      z: 0,
      rcode: 0,
      qdcount: 1,
      ancount: 2,
      nscount: 0,
      arcount: 0
    }

    assert {:ok, binary} = Header.serialize(header)
    assert byte_size(binary) == 12
    assert {:ok, ^header} = Header.deserialize(binary)
  end

  test "Question serialize/deserialize roundtrip" do
    question = %Question{
      qname: "www.example.com",
      qtype: 1,
      qclass: 1
    }

    assert {:ok, binary} = Question.serialize(question)
    assert {:ok, ^question, next} = Question.deserialize(binary, 0)
    assert next == byte_size(binary)
  end
end
