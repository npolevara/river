defmodule CodexRiver.CodexAppServerLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexRiver.Auth
  alias CodexRiver.CodexAppServer.Client

  setup do
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :warning) end)
    :ok
  end

  test "logs one complete app-server question and answer without exposing the bearer token" do
    token = "raw-secret-token-for-log-test"
    token_id = Auth.token_id(token)
    client = start_client(token_id, true)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %{content: "Codex: app-server-trace-marker"}} =
                 Client.complete("app-server-trace-marker", server: client, timeout: 5_000)

        _state = :sys.get_state(client)
      end)

    token_label = String.slice(token_id, 0, 12)

    assert log =~ "CodexRiver -> app-server [token=#{token_label}]"
    assert log =~ "app-server -> CodexRiver [token=#{token_label}]"
    assert log =~ ~s("prompt":"app-server-trace-marker")
    assert log =~ ~s("content":"Codex: app-server-trace-marker")
    assert length(Regex.scan(~r/CodexRiver -> app-server/, log)) == 1
    assert length(Regex.scan(~r/app-server -> CodexRiver/, log)) == 1
    refute log =~ ~s("method":"item\/agentMessage\/delta")
    refute log =~ token
  end

  test "does not log app-server payloads when tracing is disabled" do
    client = start_client(Auth.token_id("disabled-log-token"), false)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %{content: "Codex: disabled-trace-marker"}} =
                 Client.complete("disabled-trace-marker", server: client, timeout: 5_000)

        _state = :sys.get_state(client)
      end)

    refute log =~ "CodexRiver -> app-server"
    refute log =~ "app-server -> CodexRiver"
    refute log =~ "disabled-trace-marker"
  end

  defp start_client(token_id, log_app_server?) do
    start_supervised!({Client, client_options(token_id, log_app_server?)})
  end

  defp client_options(token_id, log_app_server?) do
    [
      command: System.find_executable("ruby"),
      args: [Path.expand("../support/fake_codex_app_server.rb", __DIR__)],
      cwd: Path.expand("../..", __DIR__),
      timeout: 5_000,
      sandbox: "read-only",
      approval_policy: "never",
      token_id: token_id,
      log_app_server: log_app_server?
    ]
  end
end
