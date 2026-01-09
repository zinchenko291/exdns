defmodule Models.Dns.Zone.Validator do
  @moduledoc false

  use GenServer

  require Logger

  alias Models.Dns.Zone.Storage

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    send(self(), :scan)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    folder =
      :exdns
      |> Application.fetch_env!(:zones_folder)
      |> Path.expand(File.cwd!())

    Logger.info("[Zone.Validator] scanning zones at #{folder}")

    if File.dir?(folder) do
      pattern = Path.join(folder, "**/*.json")

      pattern
      |> Path.wildcard()
      |> Enum.each(&validate_file/1)
    else
      Logger.info("[Zone.Validator] zones folder not found: #{folder}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp validate_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content) do
      case Storage.validate_zone(json) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Zone.Validator] invalid zone file #{path}: #{reason}")
      end
    else
      {:error, reason} ->
        Logger.warning("[Zone.Validator] invalid zone file #{path}: #{inspect(reason)}")
    end
  end
end
