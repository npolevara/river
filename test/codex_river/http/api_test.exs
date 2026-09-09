defmodule CodexRiver.HTTP.APITest do
  use ExUnit.Case, async: false

  alias CodexRiver.TestHTTPClient

  test "reports when no API token is configured" do
    previous_tokens = Application.fetch_env!(:codex_river, :api_tokens)
    Application.put_env(:codex_river, :api_tokens, [])
    on_exit(fn -> Application.put_env(:codex_river, :api_tokens, previous_tokens) end)

    response = TestHTTPClient.request("GET", "/v1/models", "any-token")

    assert response.status == 503

    assert %{"error" => %{"code" => "api_token_not_configured"}} =
             Jason.decode!(response.body)
  end

  test "requires a configured bearer token" do
    response = TestHTTPClient.request("GET", "/v1/models")

    assert response.status == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert %{"error" => %{"code" => "invalid_api_key"}} = Jason.decode!(response.body)
  end

  test "lists the compatibility model" do
    response = TestHTTPClient.request("GET", "/v1/models", "test-token-a")

    assert response.status == 200

    assert %{
             "object" => "list",
             "data" => [%{"id" => "codex-app-server", "owned_by" => "local-codex"}]
           } = Jason.decode!(response.body)
  end

  test "creates chat completions and resolves model aliases" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => " gpt-5.6 ",
        "reasoning_effort" => "high",
        "messages" => [%{"role" => "user", "content" => "report-config"}]
      })

    assert response.status == 200

    assert %{
             "model" => "gpt-5.6",
             "choices" => [%{"message" => %{"content" => "gpt-5.6-sol:high"}}],
             "usage" => %{
               "prompt_tokens" => 11,
               "completion_tokens" => 3,
               "total_tokens" => 14
             }
           } = Jason.decode!(response.body)
  end

  test "returns a model error rejected by app-server" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "missing-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    assert response.status == 400

    assert %{"error" => %{"code" => "model_not_found", "param" => "model"}} =
             Jason.decode!(response.body)
  end

  test "streams Chat Completions as SSE" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "gpt-5.6-terra",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      })

    assert response.status == 200
    assert response.headers["content-type"] == "text/event-stream; charset=utf-8"
    assert response.body =~ "chat.completion.chunk"
    assert response.body =~ "Codex: "
    assert response.body =~ "\"choices\":[]"
    assert response.body =~ "data: [DONE]"
  end

  test "returns only final-answer app-server messages" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "codex-app-server",
        "messages" => [%{"role" => "user", "content" => "with-commentary"}],
        "stream" => true
      })

    assert response.status == 200
    assert response.body =~ "Final only"
    refute response.body =~ "Internal progress"
  end

  test "returns streamed client-defined function calls" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "codex-app-server",
        "messages" => [%{"role" => "user", "content" => "request-tool"}],
        "stream" => true,
        "tools" => [shell_tool()]
      })

    assert response.status == 200
    assert response.body =~ "\"finish_reason\":\"tool_calls\""
    assert response.body =~ "\"name\":\"run_shell_command\""
    assert response.body =~ "git log"
    assert response.body =~ "data: [DONE]"
  end

  test "accepts tool results on a following Chat Completions request" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "codex-app-server",
        "messages" => [
          %{"role" => "user", "content" => "request-tool"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{
                  "name" => "run_shell_command",
                  "arguments" => "{\"command\":\"git log\"}"
                }
              }
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "ok"}
        ],
        "tools" => [shell_tool()]
      })

    assert response.status == 200

    assert %{"choices" => [%{"message" => %{"content" => "Tool result accepted"}}]} =
             Jason.decode!(response.body)
  end

  test "creates and streams Responses API results" do
    complete =
      TestHTTPClient.request("POST", "/v1/responses", "test-token-a", %{
        "model" => "gpt-5.6-luna",
        "reasoning" => %{"mode" => "pro", "effort" => "medium"},
        "input" => "report-config"
      })

    assert complete.status == 200

    assert %{
             "model" => "gpt-5.6-luna",
             "status" => "completed",
             "output" => [%{"content" => [%{"text" => "gpt-5.6-luna:medium"}]}]
           } = Jason.decode!(complete.body)

    stream =
      TestHTTPClient.request("POST", "/v1/responses", "test-token-a", %{
        "model" => "gpt-5.6-terra",
        "input" => "hello",
        "stream" => true
      })

    assert stream.status == 200
    assert stream.body =~ "event: response.created"
    assert stream.body =~ "event: response.output_text.delta"
    assert stream.body =~ "event: response.completed"
  end

  test "returns OpenAI-shaped validation errors" do
    response =
      TestHTTPClient.request("POST", "/v1/chat/completions", "test-token-a", %{
        "model" => "codex-app-server",
        "messages" => []
      })

    assert response.status == 400

    assert %{"error" => %{"type" => "invalid_request_error", "param" => "messages"}} =
             Jason.decode!(response.body)
  end

  defp shell_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "run_shell_command",
        "description" => "Run a shell command",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"command" => %{"type" => "string"}},
          "required" => ["command"]
        }
      }
    }
  end
end
