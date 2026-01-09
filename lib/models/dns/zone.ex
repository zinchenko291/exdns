defmodule Models.Dns.Zone do
  @moduledoc """
  Public API for accessing domain zone data via the zone cache process.
  """

  alias Models.Dns.Zone.Cache

  @spec fetch(String.t()) :: {:ok, map()} | :not_found | {:error, String.t()}
  def fetch(domain), do: Cache.fetch(domain)

  @spec put(String.t(), map()) :: :ok | {:error, String.t()}
  def put(domain, data), do: Cache.put(domain, data)

  @spec create(String.t(), map()) :: :ok | {:error, String.t()}
  def create(domain, data), do: Cache.create(domain, data)

  @spec update(String.t(), map()) :: :ok | :not_found | {:error, String.t()}
  def update(domain, data), do: Cache.update(domain, data)

  @spec update(String.t(), map(), non_neg_integer()) :: :ok | :not_found | {:error, String.t()}
  def update(domain, data, expected_version), do: Cache.update(domain, data, expected_version)

  @spec delete(String.t()) :: :ok | :not_found | {:error, String.t()}
  def delete(domain), do: Cache.delete(domain)
end
