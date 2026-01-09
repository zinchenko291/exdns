defmodule Exdns.Http.Router do
  @moduledoc false

  use Plug.Router

  require Logger

  alias Models.Dns.Zone

  plug :match
  plug :authorize
  plug :dispatch

  get "/zones/:domain" do
    Logger.info("[HTTP] GET /zones/#{domain}")
    case Zone.fetch(domain) do
      {:ok, data} -> json(conn, 200, data)
      :not_found -> json(conn, 404, %{error: "zone not found"})
      {:error, reason} -> json(conn, 500, %{error: reason})
    end
  end

  post "/zones/:domain" do
    Logger.info("[HTTP] POST /zones/#{domain}")
    with {:ok, data} <- read_json(conn),
         :ok <- Zone.create(domain, data) do
      json(conn, 201, %{status: "created"})
    else
      {:error, reason} -> json(conn, 400, %{error: reason})
    end
  end

  put "/zones/:domain" do
    Logger.info("[HTTP] PUT /zones/#{domain}")
    with {:ok, data} <- read_json(conn),
         :ok <- Zone.update(domain, data) do
      json(conn, 200, %{status: "updated"})
    else
      :not_found -> json(conn, 404, %{error: "zone not found"})
      {:error, reason} -> json(conn, 400, %{error: reason})
    end
  end

  delete "/zones/:domain" do
    Logger.info("[HTTP] DELETE /zones/#{domain}")
    case Zone.delete(domain) do
      :ok -> json(conn, 200, %{status: "deleted"})
      :not_found -> json(conn, 404, %{error: "zone not found"})
      {:error, reason} -> json(conn, 500, %{error: reason})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp authorize(conn, _opts) do
    token =
      :exdns
      |> Application.fetch_env!(:api_token)
      |> to_string()

    case Plug.Conn.get_req_header(conn, "authentication") do
      ["Bearer " <> provided] when provided == token ->
        conn

      _ ->
        Logger.warning("[HTTP] unauthorized request")
        conn
        |> json(401, %{error: "unauthorized"})
        |> halt()
    end
  end

  defp read_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:ok, _} -> {:error, "json payload must be an object"}
          {:error, _} -> {:error, "invalid json"}
        end

      {:more, _chunk, _conn} ->
        {:error, "request body too large"}

      {:error, reason} ->
        {:error, "failed to read body: #{inspect(reason)}"}
    end
  end

  defp json(conn, status, body) do
    payload = Jason.encode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, payload)
  end
end
