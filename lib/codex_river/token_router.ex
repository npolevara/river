defmodule CodexRiver.TokenRouter do
  @moduledoc """
  Gives each authorized bearer token a dedicated Codex app-server process.

  Registry keys are SHA-256 token identifiers. Raw bearer tokens are never
  stored in process names or written to logs.
  """

  alias CodexRiver.CodexAppServer.Client

  @spec client_for(String.t()) :: {:ok, pid()} | {:error, term()}
  def client_for(token_id) when is_binary(token_id) do
    case Registry.lookup(CodexRiver.TokenRegistry, token_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> start_client(token_id)
    end
  end

  defp start_client(token_id) do
    name = {:via, Registry, {CodexRiver.TokenRegistry, token_id}}
    child = {Client, name: name, token_id: token_id}

    case DynamicSupervisor.start_child(CodexRiver.TokenSupervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
