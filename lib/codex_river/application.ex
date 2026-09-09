defmodule CodexRiver.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: CodexRiver.TokenRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: CodexRiver.TokenSupervisor},
      {Task.Supervisor, name: CodexRiver.ConnectionSupervisor}
    ]

    children =
      if Application.get_env(:codex_river, :start_server, true) do
        children ++ [CodexRiver.HTTP.Server]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: CodexRiver.Supervisor)
  end
end
