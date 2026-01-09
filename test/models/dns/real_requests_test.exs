defmodule Models.Dns.Net.RealRequestsTest do
  use ExUnit.Case, async: true

  alias Models.Dns.Net.Additional.Opt.Cookie
  alias Models.Dns.Net.Request

  @requests [
    %{
      hex: "C94E012000010000000000010568656C6C6F036E65740000010001000029100000000000000C000A00081A609B453CE69B6B",
      id: 0xC94E,
      qname: "hello.net",
      cookie: <<0x1A, 0x60, 0x9B, 0x45, 0x3C, 0xE6, 0x9B, 0x6B>>
    },
    %{
      hex: "D6C8012000010000000000010568656C6C6F036E65740000010001000029100000000000000C000A0008694CEB430739333F",
      id: 0xD6C8,
      qname: "hello.net",
      cookie: <<0x69, 0x4C, 0xEB, 0x43, 0x07, 0x39, 0x33, 0x3F>>
    },
    %{
      hex: "2EA101200001000000000001047465737403636F6D0000010001000029100000000000000C000A0008ED25CEE19C6C55AE",
      id: 0x2EA1,
      qname: "test.com",
      cookie: <<0xED, 0x25, 0xCE, 0xE1, 0x9C, 0x6C, 0x55, 0xAE>>
    }
  ]

  test "real DNS queries deserialize correctly" do
    Enum.each(@requests, fn %{hex: hex, id: id, qname: qname, cookie: cookie} ->
      binary = Base.decode16!(hex, case: :mixed)
      assert {:ok, request} = Request.deserialize(binary)

      assert request.header.id == id
      assert request.header.qdcount == 1
      assert request.header.ancount == 0
      assert request.header.nscount == 0
      assert request.header.arcount == 1

      assert [%{qname: ^qname, qtype: 1, qclass: 1}] = request.question

      assert request.additional.opt.udp_payload_size == 4096
      assert request.additional.opt.extended_rcode == 0
      assert request.additional.opt.version == 0
      assert request.additional.opt.dnssec_ok == false
      assert request.additional.opt.z == 0
      assert [%{code: 10, value: %Cookie{client: ^cookie, server: nil}}] =
               request.additional.opt.options
    end)
  end
end
