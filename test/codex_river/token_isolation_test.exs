defmodule CodexRiver.TokenIsolationTest do
  use ExUnit.Case, async: false

  alias CodexRiver.Auth
  alias CodexRiver.TestHTTPClient
  alias CodexRiver.TokenRouter

  test "different bearer tokens own different codex app-server processes" do
    response_a = chat("test-token-a", "report-instance")
    response_b = chat("test-token-b", "report-instance")

    instance_a = get_in(response_a, ["choices", Access.at(0), "message", "content"])
    instance_b = get_in(response_b, ["choices", Access.at(0), "message", "content"])

    refute instance_a == instance_b

    {:ok, client_a} = TokenRouter.client_for(Auth.token_id("test-token-a"))
    {:ok, same_client_a} = TokenRouter.client_for(Auth.token_id("test-token-a"))
    {:ok, client_b} = TokenRouter.client_for(Auth.token_id("test-token-b"))

    assert client_a == same_client_a
    refute client_a == client_b
    refute :sys.get_state(client_a).port == :sys.get_state(client_b).port
  end

  test "every request gets a fresh ephemeral thread even for the same token" do
    first = chat("test-token-a", "report-thread")
    second = chat("test-token-a", "report-thread")

    first_thread = get_in(first, ["choices", Access.at(0), "message", "content"])
    second_thread = get_in(second, ["choices", Access.at(0), "message", "content"])

    refute first_thread == second_thread
  end

  test "concurrent streams for different tokens do not cross" do
    results =
      [{"test-token-a", "alpha-only"}, {"test-token-b", "beta-only"}]
      |> Task.async_stream(
        fn {token, message} ->
          {message,
           TestHTTPClient.request("POST", "/v1/chat/completions", token, %{
             "model" => "codex-app-server",
             "messages" => [%{"role" => "user", "content" => message}],
             "stream" => true
           })}
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Map.new()

    assert results["alpha-only"].status == 200
    assert results["alpha-only"].body =~ "alpha-only"
    refute results["alpha-only"].body =~ "beta-only"

    assert results["beta-only"].status == 200
    assert results["beta-only"].body =~ "beta-only"
    refute results["beta-only"].body =~ "alpha-only"
  end

  defp chat(token, message) do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", token, %{
        "model" => "codex-app-server",
        "messages" => [%{"role" => "user", "content" => message}]
      })

    assert response.status == 200
    Jason.decode!(response.body)
  end
end
