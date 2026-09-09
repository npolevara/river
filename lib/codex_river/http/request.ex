defmodule CodexRiver.HTTP.Request do
  @moduledoc false

  @max_header_bytes 65_536
  @max_body_bytes 8_388_608
  @read_timeout 15_000

  defstruct [:method, :path, :version, :headers, :body]

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          version: String.t(),
          headers: map(),
          body: binary()
        }

  @spec read(port()) :: {:ok, t()} | {:error, atom()}
  def read(socket) do
    with {:ok, head, buffered_body} <- read_head(socket, ""),
         {:ok, method, path, version, headers} <- parse_head(head),
         {:ok, content_length} <- content_length(headers),
         {:ok, body} <- read_body(socket, buffered_body, content_length) do
      {:ok,
       %__MODULE__{
         method: method,
         path: path,
         version: version,
         headers: headers,
         body: body
       }}
    end
  end

  defp read_head(socket, data) do
    case :binary.match(data, "\r\n\r\n") do
      {index, 4} when index <= @max_header_bytes ->
        head = binary_part(data, 0, index)
        body_start = index + 4
        body = binary_part(data, body_start, byte_size(data) - body_start)
        {:ok, head, body}

      {_index, 4} ->
        {:error, :headers_too_large}

      :nomatch when byte_size(data) > @max_header_bytes ->
        {:error, :headers_too_large}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, @read_timeout) do
          {:ok, chunk} -> read_head(socket, data <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_head(head) do
    case String.split(head, "\r\n") do
      [request_line | header_lines] ->
        with {:ok, method, target, version} <- parse_request_line(request_line),
             {:ok, headers} <- parse_headers(header_lines),
             false <- chunked?(headers) do
          path = URI.parse(target).path || "/"
          {:ok, method, path, version, headers}
        else
          true -> {:error, :chunked_request_not_supported}
          {:error, _reason} = error -> error
        end

      _lines ->
        {:error, :invalid_request}
    end
  end

  defp parse_request_line(line) do
    case String.split(line, " ", parts: 3) do
      [method, target, "HTTP/" <> version] -> {:ok, method, target, version}
      _parts -> {:error, :invalid_request_line}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          key = name |> String.trim() |> String.downcase()
          {:cont, {:ok, Map.put(headers, key, String.trim(value))}}

        _parts ->
          {:halt, {:error, :invalid_header}}
      end
    end)
  end

  defp chunked?(headers) do
    headers
    |> Map.get("transfer-encoding", "")
    |> String.downcase()
    |> String.contains?("chunked")
  end

  defp content_length(headers) do
    case Map.get(headers, "content-length") do
      nil -> {:ok, 0}
      value -> parse_content_length(value)
    end
  end

  defp parse_content_length(value) do
    case Integer.parse(value) do
      {length, ""} when length >= 0 and length <= @max_body_bytes -> {:ok, length}
      {length, ""} when length > @max_body_bytes -> {:error, :body_too_large}
      _invalid -> {:error, :invalid_content_length}
    end
  end

  defp read_body(_socket, buffered, length) when byte_size(buffered) >= length,
    do: {:ok, binary_part(buffered, 0, length)}

  defp read_body(socket, buffered, length) do
    missing = length - byte_size(buffered)

    case :gen_tcp.recv(socket, missing, @read_timeout) do
      {:ok, chunk} -> read_body(socket, buffered <> chunk, length)
      {:error, reason} -> {:error, reason}
    end
  end
end
