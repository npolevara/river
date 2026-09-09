defmodule CodexRiver.TestHTTPClient do
  @moduledoc false

  def request(method, path, token \\ nil, body \\ nil) do
    port = CodexRiver.HTTP.Server.port()
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    encoded_body = if is_nil(body), do: "", else: Jason.encode!(body)

    headers =
      [
        "host: 127.0.0.1\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(encoded_body)}\r\n"
      ] ++ if(token, do: ["authorization: Bearer #{token}\r\n"], else: [])

    :ok =
      :gen_tcp.send(socket, [method, " ", path, " HTTP/1.1\r\n", headers, "\r\n", encoded_body])

    response = receive_all(socket, "")
    :gen_tcp.close(socket)
    parse_response(response)
  end

  defp receive_all(socket, data) do
    case :gen_tcp.recv(socket, 0, 8_000) do
      {:ok, chunk} -> receive_all(socket, data <> chunk)
      {:error, :closed} -> data
    end
  end

  defp parse_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status_string | _reason] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status_string), headers: headers, body: body}
  end
end
