defmodule Models.Dns.ZoneTest do
  use ExUnit.Case, async: false

  alias Models.Dns.Zone
  alias Models.Dns.Zone.Storage

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "exdns_zones_#{System.unique_integer([:positive])}")
    Application.put_env(:exdns, :zones_folder, tmp_dir)
    Application.put_env(:exdns, :replication_quorum_ratio, 0.0)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    :ok
  end

  test "sharded path uses md5 prefix" do
    domain = "hello.com"
    {:ok, path} = Storage.path_for(domain)
    hash = :crypto.hash(:md5, domain) |> Base.encode16(case: :lower)

    shard1 = String.slice(hash, 0, 2)
    shard2 = String.slice(hash, 2, 2)

    assert String.contains?(path, Path.join([shard1, shard2]))
    assert String.ends_with?(path, "#{domain}.json")
  end

  test "put and fetch zone via cache" do
    domain = "example.com"
    data = %{"records" => [%{"type" => "A", "data" => "1.2.3.4"}]}

    assert :ok = Zone.put(domain, data)
    assert {:ok, ^data} = Zone.fetch(domain)
  end

  test "create/update/delete zone" do
    domain = "create.example"
    data = %{"records" => [%{"type" => "A", "data" => "10.0.0.1"}]}
    updated = %{"records" => [%{"type" => "A", "data" => "10.0.0.2"}]}

    assert :ok = Zone.create(domain, data)
    assert {:error, _} = Zone.create(domain, data)
    assert {:ok, %{"version" => 1} = stored} = Zone.fetch(domain)
    assert stored["records"] == data["records"]

    assert :ok = Zone.update(domain, Map.put(updated, "version", 1))
    assert {:ok, %{"version" => 2} = stored} = Zone.fetch(domain)
    assert stored["records"] == updated["records"]

    assert :ok = Zone.delete(domain)
    assert :not_found = Zone.fetch(domain)
    assert :not_found = Zone.delete(domain)
  end

  test "fetch missing zone returns not_found" do
    assert :not_found = Zone.fetch("missing.example")
  end

  test "update requires matching version" do
    domain = "versioned.example"
    data = %{"records" => [%{"type" => "A", "data" => "10.0.0.3"}]}
    assert :ok = Zone.create(domain, data)
    assert {:error, _} = Zone.update(domain, data)
    assert {:error, _} = Zone.update(domain, Map.put(data, "version", 2))
    assert :ok = Zone.update(domain, Map.put(data, "version", 1))
  end

  test "rollback when quorum fails" do
    Application.put_env(:exdns, :replication_quorum_ratio, 2.0)

    domain = "rollback.example"
    data = %{"records" => [%{"type" => "A", "data" => "10.0.0.9"}]}

    assert {:error, _, _} = Zone.create(domain, data)
    assert :not_found = Zone.fetch(domain)

    Application.put_env(:exdns, :replication_quorum_ratio, 0.0)
    assert :ok = Zone.create(domain, data)
    assert {:ok, %{"version" => 1}} = Zone.fetch(domain)

    Application.put_env(:exdns, :replication_quorum_ratio, 2.0)
    assert {:error, _, _} = Zone.update(domain, Map.put(data, "version", 1))
    assert {:ok, %{"version" => 1} = stored} = Zone.fetch(domain)
    assert stored["records"] == data["records"]

    assert {:error, _, _} = Zone.delete(domain)
    assert {:ok, %{"version" => 1}} = Zone.fetch(domain)
  end
end
