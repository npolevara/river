defmodule CodexRiver.Auth do
  @moduledoc false

  @spec authorize(map()) :: {:ok, String.t()} | {:error, map()}
  def authorize(headers) do
    tokens = configured_tokens()

    cond do
      tokens == [] ->
        {:error,
         error(
           503,
           "The API bearer token is not configured",
           "server_error",
           "api_token_not_configured"
         )}

      true ->
        authorize_header(Map.get(headers, "authorization"), tokens)
    end
  end

  @spec token_id(String.t()) :: String.t()
  def token_id(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp configured_tokens do
    :codex_river
    |> Application.get_env(:api_tokens, [])
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
  end

  defp authorize_header("Bearer " <> supplied_token, tokens) do
    supplied_digest = :crypto.hash(:sha256, supplied_token)

    if Enum.any?(tokens, &:crypto.hash_equals(supplied_digest, :crypto.hash(:sha256, &1))) do
      {:ok, Base.encode16(supplied_digest, case: :lower)}
    else
      unauthorized()
    end
  end

  defp authorize_header(_header, _tokens), do: unauthorized()

  defp unauthorized do
    {:error,
     error(401, "Invalid authentication credentials", "authentication_error", "invalid_api_key")}
  end

  defp error(status, message, type, code) do
    %{status: status, message: message, type: type, param: nil, code: code}
  end
end
