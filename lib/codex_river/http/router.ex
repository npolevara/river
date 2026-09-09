defmodule CodexRiver.HTTP.Router do
  @moduledoc false

  require Logger

  alias CodexRiver.Auth
  alias CodexRiver.HTTP.Response, as: HTTPResponse
  alias CodexRiver.LLM
  alias CodexRiver.OpenAI.ChatCompletion
  alias CodexRiver.OpenAI.ChatCompletionRequest
  alias CodexRiver.OpenAI.Response
  alias CodexRiver.OpenAI.ResponseRequest
  alias CodexRiver.TokenRouter

  @spec dispatch(port(), CodexRiver.HTTP.Request.t()) :: :ok | {:error, term()}
  def dispatch(socket, %{method: "OPTIONS"}), do: HTTPResponse.empty(socket, 204)

  def dispatch(socket, %{method: "GET", path: "/health"}),
    do: HTTPResponse.json(socket, 200, %{status: "ok"})

  def dispatch(socket, request) do
    case Auth.authorize(request.headers) do
      {:ok, token_id} -> dispatch_authorized(socket, request, token_id)
      {:error, error} -> HTTPResponse.error(socket, error)
    end
  end

  defp dispatch_authorized(socket, %{method: "GET", path: "/v1/models"}, _token_id) do
    model = Application.fetch_env!(:codex_river, :public_model)

    HTTPResponse.json(socket, 200, %{
      object: "list",
      data: [%{id: model, object: "model", created: 0, owned_by: "local-codex"}]
    })
  end

  defp dispatch_authorized(
         socket,
         %{method: "POST", path: "/v1/chat/completions"} = request,
         token_id
       ) do
    with {:ok, params} <- decode_json(request.body),
         {:ok, parsed_request} <- ChatCompletionRequest.parse(params),
         {:ok, client} <- TokenRouter.client_for(token_id) do
      if parsed_request.stream do
        stream_chat(socket, parsed_request, client)
      else
        complete_chat(socket, parsed_request, client)
      end
    else
      {:error, %{status: _status} = error} -> HTTPResponse.error(socket, error)
      {:error, reason} -> HTTPResponse.error(socket, backend_error(reason))
    end
  end

  defp dispatch_authorized(socket, %{method: "POST", path: "/v1/responses"} = request, token_id) do
    with {:ok, params} <- decode_json(request.body),
         {:ok, parsed_request} <- ResponseRequest.parse(params),
         {:ok, client} <- TokenRouter.client_for(token_id) do
      if parsed_request.stream do
        stream_response(socket, parsed_request, client)
      else
        complete_response(socket, parsed_request, client)
      end
    else
      {:error, %{status: _status} = error} -> HTTPResponse.error(socket, error)
      {:error, reason} -> HTTPResponse.error(socket, backend_error(reason))
    end
  end

  defp dispatch_authorized(socket, %{path: path}, _token_id)
       when path in ["/v1/chat/completions", "/v1/responses", "/v1/models"] do
    HTTPResponse.error(socket, request_error(405, "Method not allowed"))
  end

  defp dispatch_authorized(socket, _request, _token_id) do
    HTTPResponse.error(socket, request_error(404, "Route not found"))
  end

  defp complete_chat(socket, request, client) do
    case LLM.complete(request.messages, chat_options(request, client)) do
      {:ok, completion} ->
        HTTPResponse.json(
          socket,
          200,
          ChatCompletion.response(
            request,
            completion,
            ChatCompletion.id(),
            System.system_time(:second)
          )
        )

      {:error, reason} ->
        HTTPResponse.error(socket, backend_error(reason))
    end
  end

  defp complete_response(socket, request, client) do
    case LLM.complete(request.messages, response_options(request, client)) do
      {:ok, completion} ->
        HTTPResponse.json(
          socket,
          200,
          Response.response(
            request,
            completion,
            Response.id(),
            Response.message_id(),
            System.system_time(:second)
          )
        )

      {:error, reason} ->
        HTTPResponse.error(socket, backend_error(reason))
    end
  end

  defp stream_chat(socket, request, client) do
    id = ChatCompletion.id()
    created = System.system_time(:second)
    owner = self()
    stream_ref = make_ref()

    with :ok <- HTTPResponse.start_sse(socket),
         :ok <- HTTPResponse.sse(socket, ChatCompletion.role_chunk(request, id, created)) do
      task =
        Task.Supervisor.async_nolink(CodexRiver.ConnectionSupervisor, fn ->
          options =
            request
            |> chat_options(client)
            |> maybe_stream_chat_deltas(request, owner, stream_ref)

          LLM.complete(request.messages, options)
        end)

      chat_stream_loop(socket, request, task, stream_ref, id, created)
    end
  end

  defp chat_stream_loop(socket, request, task, stream_ref, id, created) do
    receive do
      {^stream_ref, :delta, text} ->
        case HTTPResponse.sse(socket, ChatCompletion.content_chunk(request, id, created, text)) do
          :ok -> chat_stream_loop(socket, request, task, stream_ref, id, created)
          {:error, _reason} -> stop_task(task)
        end

      {task_ref, result} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_chat_stream(socket, request, id, created, result)

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
        finish_chat_stream(socket, request, id, created, {:error, {:task_exit, reason}})
    after
      stream_timeout() ->
        Task.shutdown(task, :brutal_kill)
        finish_chat_stream(socket, request, id, created, {:error, :timeout})
    end
  end

  defp finish_chat_stream(socket, request, id, created, {:ok, completion}) do
    chunks =
      buffered_chat_chunks(request, id, created, completion) ++
        [ChatCompletion.stop_chunk(request, id, created, completion)] ++
        if(request.include_usage,
          do: [ChatCompletion.usage_chunk(request, id, created, completion.usage)],
          else: []
        ) ++ [ChatCompletion.done()]

    send_all(socket, chunks)
  end

  defp finish_chat_stream(socket, _request, _id, _created, {:error, reason}) do
    send_all(socket, [ChatCompletion.error(backend_error(reason)), ChatCompletion.done()])
  end

  defp buffered_chat_chunks(request, id, created, %{tool_calls: [_first | _rest] = calls}),
    do: [ChatCompletion.tool_calls_chunk(request, id, created, calls)]

  defp buffered_chat_chunks(%{tools: [_first | _rest]} = request, id, created, completion)
       when is_binary(completion.content) and completion.content != "",
       do: [ChatCompletion.content_chunk(request, id, created, completion.content)]

  defp buffered_chat_chunks(_request, _id, _created, _completion), do: []

  defp stream_response(socket, request, client) do
    id = Response.id()
    message_id = Response.message_id()
    created = System.system_time(:second)
    owner = self()
    stream_ref = make_ref()

    with :ok <- HTTPResponse.start_sse(socket),
         :ok <- send_all(socket, Response.started_events(request, id, message_id, created)) do
      task =
        Task.Supervisor.async_nolink(CodexRiver.ConnectionSupervisor, fn ->
          options =
            request
            |> response_options(client)
            |> Keyword.put(:on_delta, fn text -> send(owner, {stream_ref, :delta, text}) end)

          LLM.complete(request.messages, options)
        end)

      response_stream_loop(socket, request, task, stream_ref, id, message_id, created, 3)
    end
  end

  defp response_stream_loop(socket, request, task, stream_ref, id, message_id, created, sequence) do
    receive do
      {^stream_ref, :delta, text} ->
        case HTTPResponse.sse(socket, Response.delta(message_id, text, sequence)) do
          :ok ->
            response_stream_loop(
              socket,
              request,
              task,
              stream_ref,
              id,
              message_id,
              created,
              sequence + 1
            )

          {:error, _reason} ->
            stop_task(task)
        end

      {task_ref, result} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_response_stream(socket, request, id, message_id, created, sequence, result)

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
        finish_response_stream(
          socket,
          request,
          id,
          message_id,
          created,
          sequence,
          {:error, {:task_exit, reason}}
        )
    after
      stream_timeout() ->
        Task.shutdown(task, :brutal_kill)

        finish_response_stream(
          socket,
          request,
          id,
          message_id,
          created,
          sequence,
          {:error, :timeout}
        )
    end
  end

  defp finish_response_stream(
         socket,
         request,
         id,
         message_id,
         created,
         sequence,
         {:ok, completion}
       ) do
    send_all(
      socket,
      Response.completed_events(request, completion, id, message_id, created, sequence)
    )
  end

  defp finish_response_stream(
         socket,
         _request,
         _id,
         _message_id,
         _created,
         sequence,
         {:error, reason}
       ) do
    HTTPResponse.sse(socket, Response.error(backend_error(reason), sequence))
  end

  defp send_all(socket, payloads) do
    Enum.reduce_while(payloads, :ok, fn payload, :ok ->
      case HTTPResponse.sse(socket, payload) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stop_task(task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp chat_options(request, client) do
    [
      server: client,
      model: request.model,
      reasoning_effort: request.reasoning_effort,
      tools: request.tools,
      tool_choice: request.tool_choice
    ]
  end

  defp maybe_stream_chat_deltas(options, %{tools: []}, owner, stream_ref) do
    Keyword.put(options, :on_delta, fn text -> send(owner, {stream_ref, :delta, text}) end)
  end

  defp maybe_stream_chat_deltas(options, _request, _owner, _stream_ref), do: options

  defp response_options(request, client) do
    [
      server: client,
      model: request.model,
      reasoning_effort: request.reasoning.effort,
      reasoning_mode: request.reasoning.mode
    ]
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, params} when is_map(params) -> {:ok, params}
      {:ok, _other} -> {:error, request_error(400, "JSON body must be an object")}
      {:error, _error} -> {:error, request_error(400, "Invalid JSON body")}
    end
  end

  defp request_error(status, message) do
    %{status: status, message: message, type: "invalid_request_error", param: nil, code: nil}
  end

  defp backend_error({:unsupported_model, _details} = reason) do
    Logger.info("Codex app-server rejected a requested model: #{inspect(reason)}")

    %{
      message: "The requested model is not available in the local Codex environment",
      type: "invalid_request_error",
      param: "model",
      code: "model_not_found",
      status: 400
    }
  end

  defp backend_error({:unsupported_reasoning_effort, _details} = reason) do
    Logger.info("Codex app-server rejected a requested reasoning effort: #{inspect(reason)}")

    %{
      message: "The requested reasoning effort is not available for this model",
      type: "invalid_request_error",
      param: "reasoning.effort",
      code: "unsupported_value",
      status: 400
    }
  end

  defp backend_error(reason) when reason in [:codex_app_server_not_found, :not_started] do
    backend_unavailable(reason)
  end

  defp backend_error({kind, _details} = reason)
       when kind in [:codex_app_server_not_found, :codex_app_server_start_failed] do
    backend_unavailable(reason)
  end

  defp backend_error(:timeout) do
    %{
      message: "The local Codex app-server request timed out",
      type: "server_error",
      param: nil,
      code: "backend_timeout",
      status: 504
    }
  end

  defp backend_error(reason) do
    Logger.error("Codex app-server completion failed: #{inspect(reason)}")

    %{
      message: "The local Codex app-server backend could not complete the request",
      type: "server_error",
      param: nil,
      code: "backend_error",
      status: 502
    }
  end

  defp backend_unavailable(reason) do
    Logger.error("Codex app-server is unavailable: #{inspect(reason)}")

    %{
      message: "The local Codex app-server backend is unavailable",
      type: "server_error",
      param: nil,
      code: "backend_unavailable",
      status: 503
    }
  end

  defp stream_timeout do
    options = Application.get_env(:codex_river, CodexRiver.CodexAppServer.Client, [])
    Keyword.get(options, :timeout, 120_000) + 1_000
  end
end
