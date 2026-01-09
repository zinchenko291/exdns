defmodule Models.Dns.Net.AdditionalTest do
  use ExUnit.Case, async: true

  alias Models.Dns.Net.Additional
  alias Models.Dns.Net.Additional.{Opt, Record}
  alias Models.Dns.Net.Additional.Opt.{Cookie, Option}

  test "serialize/deserialize additional records" do
    record = %Record{
      name: "extra.example.com",
      type: 1,
      class: 1,
      ttl: 300,
      rdata: <<127, 0, 0, 1>>
    }

    additional = %Additional{records: [record]}

    assert {:ok, bin} = Additional.serialize(additional)
    assert {:ok, ^additional, next} = Additional.deserialize(bin, 0, 1)
    assert next == byte_size(bin)
  end

  test "serialize/deserialize EDNS OPT with DNS cookie" do
    client_cookie = <<1, 2, 3, 4, 5, 6, 7, 8>>
    server_cookie = <<9, 10, 11, 12, 13, 14, 15, 16>>
    cookie_data = client_cookie <> server_cookie

    opt =
      %Opt{
        udp_payload_size: 1232,
        extended_rcode: 0,
        version: 0,
        dnssec_ok: true,
        z: 0,
        options: [
          %Option{
            code: 10,
            data: cookie_data,
            value: %Cookie{client: client_cookie, server: server_cookie}
          }
        ]
      }

    additional = %Additional{opt: opt}

    assert {:ok, bin} = Additional.serialize(additional)
    assert {:ok, parsed, next} = Additional.deserialize(bin, 0, 1)
    assert parsed.opt == opt
    assert parsed.records == []
    assert next == byte_size(bin)
  end
end
