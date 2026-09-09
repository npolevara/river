defmodule CodexRiver.HTTP.Response do
  @moduledoc false

  @cors_headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"},
    {"access-control-allow-headers", "authorization, content-type"}
  ]

  @spec json(port(), pos_integer(), map(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def json(socket, status, value, extra_headers \\ []) do
    body = Jason.encode!(value)

    send_response(socket, status, body, [
      {"content-type", "application/json; charset=utf-8"},
      {"content-length", Integer.to_string(byte_size(body))}
      | extra_headers
    ])
  end

  @spec empty(port(), pos_integer(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def empty(socket, status, extra_headers \\ []) do
    send_response(socket, status, "", [{"content-length", "0"} | extra_headers])
  end

  @spec start_sse(port()) :: :ok | {:error, term()}
  def start_sse(socket) do
    send_headers(socket, 200, [
      {"content-type", "text/event-stream; charset=utf-8"},
      {"cache-control", "no-cache, no-transform"},
      {"x-accel-buffering", "no"}
    ])
  end

  @spec sse(port(), iodata()) :: :ok | {:error, term()}
  def sse(socket, payload), do: :gen_tcp.send(socket, payload)

  @spec error(port(), map()) :: :ok | {:error, term()}
  def error(socket, error) do
    body = %{error: Map.take(error, [:message, :type, :param, :code])}
    extra = if error.status == 401, do: [{"www-authenticate", "Bearer"}], else: []
    json(socket, error.status, body, extra)
  end

  defp send_response(socket, status, body, headers) do
    with :ok <- send_headers(socket, status, headers) do
      :gen_tcp.send(socket, body)
    end
  end

  defp send_headers(socket, status, headers) do
    headers =
      @cors_headers ++
        headers ++
        [
          {"connection", "close"},
          {"server", "codex-river"}
        ]

    encoded_headers = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason(status),
      "\r\n",
      encoded_headers,
      "\r\n"
    ])
  end

  defp reason(200), do: "OK"
  defp reason(204), do: "No Content"
  defp reason(400), do: "Bad Request"
  defp reason(401), do: "Unauthorized"
  defp reason(404), do: "Not Found"
  defp reason(405), do: "Method Not Allowed"
  defp reason(413), do: "Content Too Large"
  defp reason(500), do: "Internal Server Error"
  defp reason(502), do: "Bad Gateway"
  defp reason(503), do: "Service Unavailable"
  defp reason(504), do: "Gateway Timeout"
  defp reason(_status), do: "Error"
end
