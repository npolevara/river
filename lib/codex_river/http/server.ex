defmodule CodexRiver.HTTP.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexRiver.HTTP.Connection

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(options) do
    ip = Keyword.get(options, :ip, Application.fetch_env!(:codex_river, :bind_ip))
    port = Keyword.get(options, :port, Application.fetch_env!(:codex_river, :port))

    listen_options = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      nodelay: true,
      backlog: 1024,
      ip: ip
    ]

    with {:ok, listener} <- :gen_tcp.listen(port, listen_options),
         {:ok, {_address, actual_port}} <- :inet.sockname(listener),
         {:ok, acceptor} <- start_acceptor(listener) do
      Logger.info("CodexRiver listening on http://#{format_ip(ip)}:#{actual_port}")
      {:ok, %{listener: listener, port: actual_port, acceptor: acceptor}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp start_acceptor(listener) do
    Task.Supervisor.start_child(CodexRiver.ConnectionSupervisor, fn -> accept_loop(listener) end)
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        hand_off(socket)
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("HTTP accept failed: #{inspect(reason)}")
        accept_loop(listener)
    end
  end

  defp hand_off(socket) do
    case Task.Supervisor.start_child(CodexRiver.ConnectionSupervisor, fn ->
           receive do
             {:serve, owned_socket} -> Connection.serve(owned_socket)
           end
         end) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(socket, pid) do
          :ok -> send(pid, {:serve, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp format_ip(ip) do
    ip |> :inet.ntoa() |> List.to_string()
  end
end
