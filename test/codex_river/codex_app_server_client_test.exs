defmodule CodexRiver.CodexAppServerClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexRiver.CodexAppServer.Client

  setup do
    %{client: start_supervised!({Client, client_options()})}
  end

  test "falls back from none to an advertised low effort", %{client: client} do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{content: "gpt-5.6-sol:low"}} =
                 complete(client, "gpt-5.6-sol", "none")
      end)

    assert log =~ "reasoning effort fallback: requested=none effective=low"
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

  defp complete(client, model, effort) do
    Client.complete("report-config",
      server: client,
      model: model,
      reasoning_effort: effort,
      timeout: 5_000
    )
  end

  defp client_options do
    [
      command: System.find_executable("ruby"),
      args: [Path.expand("../support/fake_codex_app_server.rb", __DIR__)],
      cwd: Path.expand("../..", __DIR__),
      timeout: 5_000,
      sandbox: "read-only",
      approval_policy: "never"
    ]
  end
end
