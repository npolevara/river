defmodule CodexRiver.CodexAppServerClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexRiver.CodexAppServer.Client

  setup do
    %{client: start_supervised!({Client, client_options()})}
  end

  test "falls back from none to an advertised low effort without logging it", %{client: client} do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{content: "gpt-5.6-sol:low"}} =
                 complete(client, "gpt-5.6-sol", "none")
      end)

    refute log =~ "reasoning effort fallback"
  end

  test "uses the model selected by thread start instead of the catalog default", %{client: client} do
    assert {:ok, %{content: "gpt-5.6-sol:low"}} = complete(client, nil, "none")
  end

  test "falls back from minimal to an advertised low effort", %{client: client} do
    assert {:ok, %{content: "gpt-5.6-sol:low"}} =
             complete(client, "gpt-5.6-sol", "minimal")
  end

  test "forwards none unchanged when the model advertises it", %{client: client} do
    assert {:ok, %{content: "gpt-5.6-terra:none"}} =
             complete(client, "gpt-5.6-terra", "none")
  end

  test "forwards minimal unchanged when the model advertises it", %{client: client} do
    assert {:ok, %{content: "minimal-model:minimal"}} =
             complete(client, "minimal-model", "minimal")
  end

  test "forwards every advertised effort unchanged", %{client: client} do
    for effort <- ~w(low medium high xhigh max) do
      assert {:ok, %{content: content}} = complete(client, "gpt-5.6-sol", effort)
      assert content == "gpt-5.6-sol:#{effort}"
    end
  end

  test "preserves the structured unsupported effort error", %{client: client} do
    assert {:error, {:unsupported_reasoning_effort, %{"code" => -32_602}}} =
             complete(client, "gpt-5.6-sol", "unsupported")
  end

  test "does not request capabilities or send effort when none was requested", %{client: client} do
    assert {:ok, %{content: content}} =
             Client.complete("report-protocol",
               server: client,
               model: "gpt-5.6-sol",
               timeout: 5_000
             )

    assert %{"modelListCalls" => 0, "effortPresent" => false, "effort" => nil} =
             Jason.decode!(content)
  end

  test "does not guess when capability metadata is malformed", %{client: client} do
    assert {:error, {:unsupported_reasoning_effort, %{"code" => -32_602}}} =
             complete(client, "malformed-model", "none")
  end

  test "keeps model capabilities local to concurrent operations", %{client: client} do
    tasks = [
      Task.async(fn -> complete(client, "gpt-5.6-sol", "none") end),
      Task.async(fn -> complete(client, "gpt-5.6-terra", "none") end)
    ]

    assert [
             {:ok, %{content: "gpt-5.6-sol:low"}},
             {:ok, %{content: "gpt-5.6-terra:none"}}
           ] = Enum.map(tasks, &Task.await(&1, 6_000))
  end

  test "forces every initial request to luna with low effort" do
    client =
      start_supervised!(
        {Client, client_options(force_low: true)},
        id: :force_low_client
      )

    assert {:ok, %{content: "gpt-5.6-luna:low"}} =
             complete(client, "gpt-5.6-sol", "high")
  end

  test "switches down after overload and preserves reasoning effort", %{client: client} do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{content: "gpt-5.6-luna:high"}} =
                 Client.complete("overload-until:gpt-5.6-luna",
                   server: client,
                   model: "gpt-5.6-sol",
                   reasoning_effort: "high",
                   timeout: 5_000
                 )
      end)

    assert log =~ "from=gpt-5.6-sol to=gpt-5.6-terra effort=high switch=1/4"
    assert log =~ "from=gpt-5.6-terra to=gpt-5.6-luna effort=high switch=2/4"
  end

  test "preserves the negotiated effort when switching models", %{client: client} do
    assert {:ok, %{content: "gpt-5.6-terra:low"}} =
             Client.complete("overload-until:gpt-5.6-terra",
               server: client,
               model: "gpt-5.6-sol",
               reasoning_effort: "none",
               timeout: 5_000
             )
  end

  test "switches upward when the lowest model is overloaded", %{client: client} do
    assert {:ok, %{content: "gpt-5.6-sol:medium"}} =
             Client.complete("overload-until:gpt-5.6-sol",
               server: client,
               model: "gpt-5.6-luna",
               reasoning_effort: "medium",
               timeout: 5_000
             )
  end

  test "returns the overload after four model switches", %{client: client} do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        assert {:error,
                {:app_server_turn_failed,
                 %{
                   "codexErrorInfo" => "serverOverloaded",
                   "additionalDetails" => %{"model" => "gpt-5.6-sol"}
                 }}} =
                 Client.complete("overload-always",
                   server: client,
                   model: "gpt-5.6-sol",
                   reasoning_effort: "low",
                   timeout: 5_000
                 )
      end)

    switches =
      log
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "model switch after overload"))

    assert length(switches) == 4
    assert Enum.at(switches, 0) =~ "from=gpt-5.6-sol to=gpt-5.6-terra"
    assert Enum.at(switches, 1) =~ "from=gpt-5.6-terra to=gpt-5.6-luna"
    assert Enum.at(switches, 2) =~ "from=gpt-5.6-luna to=gpt-5.6-terra"
    assert Enum.at(switches, 3) =~ "from=gpt-5.6-terra to=gpt-5.6-sol"
  end

  defp complete(client, model, effort) do
    Client.complete("report-config",
      server: client,
      model: model,
      reasoning_effort: effort,
      timeout: 5_000
    )
  end

  defp client_options(overrides \\ []) do
    [
      command: System.find_executable("ruby"),
      args: [Path.expand("../support/fake_codex_app_server.rb", __DIR__)],
      cwd: Path.expand("../..", __DIR__),
      timeout: 5_000,
      sandbox: "read-only",
      approval_policy: "never"
    ]
    |> Keyword.merge(overrides)
  end
end
