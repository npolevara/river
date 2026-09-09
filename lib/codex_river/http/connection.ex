defmodule CodexRiver.HTTP.Connection do
  @moduledoc false

  require Logger

  alias CodexRiver.HTTP.Request
  alias CodexRiver.HTTP.Response
  alias CodexRiver.HTTP.Router

  @spec serve(port()) :: :ok
  def serve(socket) do
    case Request.read(socket) do
      {:ok, request} ->
        Router.dispatch(socket, request)

      {:error, :body_too_large} ->
        Response.error(socket, request_error(413, "Request body is too large"))

      {:error, reason} ->
        Response.error(socket, request_error(400, "Malformed HTTP request")) |> log(reason)
    end

    :gen_tcp.close(socket)
    :ok
  rescue
    error ->
      Logger.error("HTTP connection failed: #{Exception.message(error)}")
      :gen_tcp.close(socket)
      :ok
  catch
    kind, reason ->
      Logger.error("HTTP connection failed: #{inspect({kind, reason})}")
      :gen_tcp.close(socket)
      :ok
  end

  defp request_error(status, message) do
    %{status: status, message: message, type: "invalid_request_error", param: nil, code: nil}
  end

  defp log(result, reason) do
    Logger.debug("Rejected HTTP request: #{inspect(reason)}")
    result
  end
end
