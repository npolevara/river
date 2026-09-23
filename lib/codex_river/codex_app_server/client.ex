defmodule CodexRiver.CodexAppServer.Client do
  @moduledoc """
  Concurrent client backed by one long-lived `codex app-server` stdio process.

  A Client belongs to exactly one bearer-token hash. Every completion creates a
  new ephemeral app-server thread, so requests cannot inherit transcript state
  from each other or add entries to the user's Codex thread history.
  """

  use GenServer

  require Logger

  @default_timeout 120_000
  @lowest_model "gpt-5.6-luna"
  @lowest_reasoning_effort "low"
  @max_overload_model_switches 4

  defstruct port: nil,
            status: :disconnected,
            buffer: "",
            next_id: 1,
            pending: %{},
            operations: %{},
            token_id: nil,
            config: []

  @type result :: %{
          required(:content) => String.t(),
          optional(:usage) => map() | nil,
          optional(:stop_reason) => String.t() | nil
        }

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @spec complete(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def complete(prompt, options) when is_binary(prompt) do
    server = Keyword.fetch!(options, :server)
    timeout = Keyword.get(options, :timeout, configured_timeout())

    GenServer.call(
      server,
      {:complete, prompt, Keyword.get(options, :model), Keyword.get(options, :reasoning_effort),
       Keyword.get(options, :on_delta), timeout},
      timeout + 1_000
    )
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :not_started}
    :exit, reason -> {:error, {:client_exit, reason}}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    config =
      Application.get_env(:codex_river, __MODULE__, [])
      |> Keyword.merge(Keyword.drop(options, [:name, :token_id]))

    {:ok, %__MODULE__{config: config, token_id: Keyword.get(options, :token_id)}}
  end

  @impl true
  def handle_call({:complete, prompt, model, reasoning_effort, on_delta, timeout}, from, state) do
    operation_ref = make_ref()
    caller = elem(from, 0)
    {model, reasoning_effort} = maybe_force_lowest_model(state, model, reasoning_effort)

    operation = %{
      from: from,
      caller_monitor: Process.monitor(caller),
      timer: Process.send_after(self(), {:operation_timeout, operation_ref}, timeout),
      phase: :queued,
      prompt: prompt,
      model: model,
      requested_reasoning_effort: reasoning_effort,
      reasoning_effort: reasoning_effort,
      supported_reasoning_efforts: :unknown,
      selected_model: nil,
      thread_id: nil,
      turn_id: nil,
      overload_model_switches: 0,
      overload_model_direction: nil,
      content: "",
      usage: nil,
      agent_items: %{},
      on_delta: on_delta
    }

    state = put_in(state.operations[operation_ref], operation)

    case ensure_connected(state) do
      {:ok, %{status: :ready} = state} ->
        {:noreply, start_thread(state, operation_ref)}

      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        {:noreply, finish_operation(state, operation_ref, {:error, reason}, cleanup: false)}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)
    {:noreply, Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, transport_stopped(state, {:exit_status, status})}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:noreply, transport_stopped(state, {:exit, reason})}

  def handle_info({:operation_timeout, operation_ref}, state),
    do: {:noreply, finish_operation(state, operation_ref, {:error, :timeout})}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.operations, fn {_ref, operation} ->
           operation.caller_monitor == monitor
         end) do
      {operation_ref, _operation} -> {:noreply, abandon_operation(state, operation_ref)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ensure_connected(%{status: status} = state) when status in [:initializing, :ready],
    do: {:ok, state}

  defp ensure_connected(state) do
    with {:ok, command} <- resolve_command(state.config[:command]),
         {:ok, port} <- open_port(command, state.config) do
      state = %{state | port: port, status: :initializing, buffer: ""}

      case send_request(state, "initialize", initialize_params(), :initialize) do
        {:ok, state} -> {:ok, state}
        {:error, reason, state} -> {:error, reason, close_transport(state)}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp initialize_params do
    %{
      "clientInfo" => %{
        "name" => "codex_river",
        "title" => "CodexRiver",
        "version" => to_string(Application.spec(:codex_river, :vsn))
      }
    }
  end

  defp resolve_command(nil), do: resolve_command("codex")

  defp resolve_command(command) when is_binary(command) do
    cond do
      Path.type(command) == :absolute and File.regular?(command) -> {:ok, command}
      executable = System.find_executable(command) -> {:ok, executable}
      true -> {:error, {:codex_app_server_not_found, command}}
    end
  end

  defp open_port(command, config) do
    cwd = Path.expand(config[:cwd] || File.cwd!())
    args = Enum.map(config[:args] || ["app-server", "--stdio"], &to_charlist/1)

    options = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:cd, to_charlist(cwd)}
    ]

    {:ok, Port.open({:spawn_executable, to_charlist(command)}, options)}
  rescue
    error -> {:error, {:codex_app_server_start_failed, Exception.message(error)}}
  end

  defp request_model_capabilities(state, operation_ref, cursor \\ nil) do
    params =
      %{"includeHidden" => true}
      |> maybe_put("cursor", cursor)

    case send_request(state, "model/list", params, {:list_models, operation_ref}) do
      {:ok, state} -> put_in(state.operations[operation_ref].phase, :listing_models)
      {:error, _reason, state} -> start_turn_if_active(state, operation_ref)
    end
  end

  defp start_thread(state, operation_ref) do
    operation = state.operations[operation_ref]
    cwd = Path.expand(state.config[:cwd] || File.cwd!())

    params =
      %{
        "cwd" => cwd,
        "approvalPolicy" => state.config[:approval_policy] || "never",
        "sandbox" => state.config[:sandbox] || "read-only",
        "ephemeral" => true,
        "serviceName" => "codex_river"
      }
      |> maybe_put("model", operation.model)

    case send_request(state, "thread/start", params, {:start_thread, operation_ref}) do
      {:ok, state} -> put_in(state.operations[operation_ref].phase, :starting_thread)
      {:error, reason, state} -> finish_operation(state, operation_ref, {:error, reason})
    end
  end

  defp start_turn(state, operation_ref) do
    operation = state.operations[operation_ref]

    params =
      %{
        "threadId" => operation.thread_id,
        "input" => [%{"type" => "text", "text" => operation.prompt}]
      }
      |> maybe_put("effort", operation.reasoning_effort)

    case send_request(state, "turn/start", params, {:start_turn, operation_ref}) do
      {:ok, state} ->
        log_app_server_question(state, operation)
        put_in(state.operations[operation_ref].phase, :starting_turn)

      {:error, reason, state} ->
        finish_operation(state, operation_ref, {:error, reason})
    end
  end

  defp send_request(state, method, params, pending_tag) do
    id = state.next_id
    message = %{"id" => id, "method" => method, "params" => params}

    case send_message(state, message) do
      :ok ->
        {:ok, %{state | next_id: id + 1, pending: Map.put(state.pending, id, pending_tag)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp send_result(state, id, result), do: send_message(state, %{"id" => id, "result" => result})

  defp send_error(state, id, code, message) do
    send_message(state, %{"id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp send_message(%{port: port}, message) when is_port(port) do
    encoded = Jason.encode!(message)

    if Port.command(port, encoded <> "\n") do
      :ok
    else
      {:error, :codex_app_server_closed}
    end
  catch
    :error, :badarg -> {:error, :codex_app_server_closed}
  end

  defp handle_line(line, state) do
    case String.trim(line) do
      "" ->
        state

      line ->
        case Jason.decode(line) do
          {:ok, messages} when is_list(messages) ->
            Enum.reduce(messages, state, &handle_message/2)

          {:ok, message} when is_map(message) ->
            handle_message(message, state)

          {:ok, _other} ->
            state

          {:error, error} ->
            Logger.warning(
              "Ignoring invalid JSON from codex app-server: #{Exception.message(error)}"
            )

            state
        end
    end
  end

  defp handle_message(%{"method" => method, "id" => id} = request, state),
    do: handle_server_request(state, id, method, request["params"] || %{})

  defp handle_message(%{"method" => method, "params" => params}, state),
    do: handle_notification(state, method, params)

  defp handle_message(%{"method" => _method}, state), do: state

  defp handle_message(%{"id" => id} = response, state) do
    {pending_tag, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    if Map.has_key?(response, "error") do
      handle_rpc_error(state, pending_tag, response["error"])
    else
      handle_rpc_result(state, pending_tag, response["result"] || %{})
    end
  end

  defp handle_message(_message, state), do: state

  defp handle_rpc_result(state, :initialize, _result) do
    case send_message(state, %{"method" => "initialized", "params" => %{}}) do
      :ok ->
        state |> Map.put(:status, :ready) |> start_queued_operations()

      {:error, reason} ->
        state
        |> fail_all_operations({:app_server_initialization_failed, reason})
        |> close_transport()
    end
  end

  defp handle_rpc_result(state, {:list_models, operation_ref}, result) do
    case state.operations[operation_ref] do
      nil ->
        state

      operation ->
        case supported_reasoning_efforts(result, operation.selected_model) do
          {:ok, supported} ->
            state
            |> negotiate_reasoning_effort(operation_ref, supported)
            |> start_turn(operation_ref)

          :not_found ->
            case result["nextCursor"] do
              cursor when is_binary(cursor) and cursor != "" ->
                request_model_capabilities(state, operation_ref, cursor)

              _cursor ->
                start_turn(state, operation_ref)
            end

          :unknown ->
            start_turn(state, operation_ref)
        end
    end
  end

  defp handle_rpc_result(state, {:start_thread, operation_ref}, result) do
    thread_id = get_in(result, ["thread", "id"])
    selected_model = result["model"] || get_in(result, ["thread", "model"])

    case {state.operations[operation_ref], thread_id} do
      {nil, _thread_id} ->
        state

      {_operation, thread_id} when is_binary(thread_id) ->
        state
        |> put_in([Access.key(:operations), operation_ref, :thread_id], thread_id)
        |> put_in([Access.key(:operations), operation_ref, :selected_model], selected_model)
        |> continue_after_thread_start(operation_ref)

      {_operation, _thread_id} ->
        finish_operation(state, operation_ref, {:error, :invalid_thread_response})
    end
  end

  defp handle_rpc_result(state, {:start_turn, operation_ref}, result) do
    turn_id = get_in(result, ["turn", "id"])

    case state.operations[operation_ref] do
      nil ->
        state

      _operation when is_binary(turn_id) ->
        state
        |> put_in([Access.key(:operations), operation_ref, :turn_id], turn_id)
        |> put_in([Access.key(:operations), operation_ref, :phase], :running)

      _operation ->
        finish_operation(state, operation_ref, {:error, :invalid_turn_response})
    end
  end

  defp handle_rpc_result(state, {:interrupt, thread_id}, _result),
    do: unsubscribe_thread(state, thread_id)

  defp handle_rpc_result(state, :orphan_thread, result) do
    unsubscribe_thread(state, get_in(result, ["thread", "id"]))
  end

  defp handle_rpc_result(state, {:orphan_turn, thread_id}, result) do
    case get_in(result, ["turn", "id"]) do
      turn_id when is_binary(turn_id) -> interrupt_turn(state, thread_id, turn_id)
      _turn_id -> unsubscribe_thread(state, thread_id)
    end
  end

  defp handle_rpc_result(state, {:unsubscribe, _thread_id}, _result), do: state
  defp handle_rpc_result(state, _pending_tag, _result), do: state

  defp handle_rpc_error(state, {:start_thread, operation_ref}, error) do
    cond do
      server_overloaded?(error) ->
        retry_with_another_model(state, operation_ref, error)

      requested_value_error?(error, "model") ->
        finish_operation(state, operation_ref, {:error, {:unsupported_model, error}})

      true ->
        finish_operation(state, operation_ref, {:error, {:app_server_error, error}})
    end
  end

  defp handle_rpc_error(state, {:list_models, operation_ref}, _error),
    do: start_turn_if_active(state, operation_ref)

  defp handle_rpc_error(state, {:start_turn, operation_ref}, error) do
    cond do
      server_overloaded?(error) ->
        retry_with_another_model(state, operation_ref, error)

      requested_value_error?(error, "effort") ->
        finish_operation(state, operation_ref, {:error, {:unsupported_reasoning_effort, error}})

      true ->
        finish_operation(state, operation_ref, {:error, {:app_server_error, error}})
    end
  end

  defp handle_rpc_error(state, {:interrupt, thread_id}, _error),
    do: unsubscribe_thread(state, thread_id)

  defp handle_rpc_error(state, :orphan_thread, _error), do: state

  defp handle_rpc_error(state, {:orphan_turn, thread_id}, _error),
    do: unsubscribe_thread(state, thread_id)

  defp handle_rpc_error(state, {:unsubscribe, _thread_id}, _error), do: state

  defp handle_rpc_error(state, :initialize, error) do
    state
    |> fail_all_operations({:app_server_initialization_failed, error})
    |> close_transport()
  end

  defp handle_rpc_error(state, _pending_tag, _error), do: state

  defp handle_server_request(state, id, "item/commandExecution/requestApproval", _params) do
    _ = send_result(state, id, %{"decision" => "decline"})
    state
  end

  defp handle_server_request(state, id, "item/fileChange/requestApproval", _params) do
    _ = send_result(state, id, %{"decision" => "decline"})
    state
  end

  defp handle_server_request(state, id, method, _params)
       when method in ["execCommandApproval", "applyPatchApproval"] do
    decision = %{"denied" => %{"rejection" => "CodexRiver runs non-interactively"}}
    _ = send_result(state, id, %{"decision" => decision})
    state
  end

  defp handle_server_request(state, id, _method, _params) do
    _ = send_error(state, id, -32_601, "Method not supported by CodexRiver")
    state
  end

  defp handle_notification(state, "turn/started", params) do
    thread_id = params["threadId"]
    turn_id = get_in(params, ["turn", "id"])

    case operation_for_thread(state, thread_id) do
      {operation_ref, _operation} when is_binary(turn_id) ->
        put_in(state.operations[operation_ref].turn_id, turn_id)

      _other ->
        state
    end
  end

  defp handle_notification(state, "item/started", %{
         "threadId" => thread_id,
         "item" => %{"type" => "agentMessage", "id" => item_id} = item
       }) do
    case operation_for_thread(state, thread_id) do
      {operation_ref, operation} ->
        agent_item = %{phase: item["phase"], text: item["text"] || ""}

        state = put_in(state.operations[operation_ref].agent_items[item_id], agent_item)

        if deliverable_phase?(agent_item.phase) and agent_item.text != "" do
          emit_delta(operation.on_delta, agent_item.text)
          put_in(state.operations[operation_ref].content, operation.content <> agent_item.text)
        else
          state
        end

      nil ->
        state
    end
  end

  defp handle_notification(state, "item/agentMessage/delta", %{
         "threadId" => thread_id,
         "itemId" => item_id,
         "delta" => delta
       })
       when is_binary(delta) do
    case operation_for_thread(state, thread_id) do
      {operation_ref, operation} ->
        item = Map.get(operation.agent_items, item_id, %{phase: nil, text: ""})

        state =
          put_in(state.operations[operation_ref].agent_items[item_id].text, item.text <> delta)

        if deliverable_phase?(item.phase) do
          emit_delta(operation.on_delta, delta)
          put_in(state.operations[operation_ref].content, operation.content <> delta)
        else
          state
        end

      nil ->
        state
    end
  end

  defp handle_notification(state, "item/completed", %{
         "threadId" => thread_id,
         "item" => %{"type" => "agentMessage", "id" => item_id, "text" => text} = item
       })
       when is_binary(text) do
    case operation_for_thread(state, thread_id) do
      {operation_ref, operation} ->
        tracked = Map.get(operation.agent_items, item_id, %{phase: item["phase"], text: ""})
        phase = item["phase"] || tracked.phase
        missing = missing_suffix(tracked.text, text)

        state =
          put_in(state.operations[operation_ref].agent_items[item_id], %{phase: phase, text: text})

        if deliverable_phase?(phase) and missing != "" do
          emit_delta(operation.on_delta, missing)
          put_in(state.operations[operation_ref].content, operation.content <> missing)
        else
          state
        end

      nil ->
        state
    end
  end

  defp handle_notification(state, "thread/tokenUsage/updated", params) do
    case operation_for_thread(state, params["threadId"]) do
      {operation_ref, _operation} ->
        usage = get_in(params, ["tokenUsage", "last"])
        put_in(state.operations[operation_ref].usage, usage)

      nil ->
        state
    end
  end

  defp handle_notification(state, "turn/completed", %{
         "threadId" => thread_id,
         "turn" => turn
       }) do
    case operation_for_thread(state, thread_id) do
      {operation_ref, operation} ->
        finish_turn(state, operation_ref, operation, turn)

      nil ->
        state
    end
  end

  defp handle_notification(state, _method, _params), do: state

  defp finish_turn(state, operation_ref, operation, %{"status" => "completed"} = turn) do
    response = %{
      content: completed_content(operation, turn),
      usage: operation.usage,
      stop_reason: "end_turn"
    }

    log_app_server_answer(state, operation, response)
    finish_operation(state, operation_ref, {:ok, response}, cleanup: :unsubscribe)
  end

  defp finish_turn(state, operation_ref, _operation, %{"status" => "interrupted"}) do
    finish_operation(
      state,
      operation_ref,
      {:error, :app_server_turn_interrupted},
      cleanup: :unsubscribe
    )
  end

  defp finish_turn(state, operation_ref, _operation, %{"status" => "failed"} = turn) do
    if server_overloaded?(turn["error"]) do
      retry_with_another_model(state, operation_ref, turn["error"])
    else
      finish_operation(
        state,
        operation_ref,
        {:error, {:app_server_turn_failed, turn["error"]}},
        cleanup: :unsubscribe
      )
    end
  end

  defp finish_turn(state, operation_ref, _operation, turn) do
    finish_operation(
      state,
      operation_ref,
      {:error, {:invalid_turn_status, turn["status"]}},
      cleanup: :unsubscribe
    )
  end

  defp completed_content(%{content: content}, _turn) when content != "", do: content

  defp completed_content(_operation, turn) do
    turn
    |> Map.get("items", [])
    |> Enum.filter(fn
      %{"type" => "agentMessage", "phase" => phase} -> deliverable_phase?(phase)
      %{"type" => "agentMessage"} -> true
      _item -> false
    end)
    |> Enum.map_join(&(&1["text"] || ""))
  end

  defp operation_for_thread(state, thread_id) when is_binary(thread_id) do
    Enum.find(state.operations, fn {_operation_ref, operation} ->
      operation.thread_id == thread_id
    end)
  end

  defp operation_for_thread(_state, _thread_id), do: nil

  defp deliverable_phase?(phase), do: phase in [nil, "final_answer"]

  defp missing_suffix("", text), do: text

  defp missing_suffix(prefix, text) do
    if String.starts_with?(text, prefix) do
      binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
    else
      ""
    end
  end

  defp emit_delta(callback, text) when is_function(callback, 1) do
    callback.(text)
  rescue
    error -> Logger.warning("Completion delta callback failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("Completion delta callback failed: #{inspect({kind, reason})}")
  end

  defp emit_delta(_callback, _text), do: :ok

  defp log_app_server_question(state, operation) do
    log_app_server(state, "CodexRiver -> app-server", %{
      "threadId" => operation.thread_id,
      "model" => operation.model,
      "reasoningEffort" => operation.reasoning_effort,
      "prompt" => operation.prompt
    })
  end

  defp log_app_server_answer(state, operation, response) do
    log_app_server(state, "app-server -> CodexRiver", %{
      "threadId" => operation.thread_id,
      "turnId" => operation.turn_id,
      "content" => response.content,
      "stopReason" => response.stop_reason,
      "usage" => response.usage
    })
  end

  defp log_app_server(%{config: config} = state, direction, payload) do
    if config[:log_app_server] do
      Logger.debug(fn ->
        "#{direction} [token=#{token_label(state.token_id)}] #{Jason.encode!(payload)}"
      end)
    end

    :ok
  end

  defp token_label(token_id) when is_binary(token_id), do: String.slice(token_id, 0, 12)
  defp token_label(_token_id), do: "unscoped"

  defp start_queued_operations(state) do
    state.operations
    |> Enum.filter(fn {_operation_ref, operation} -> operation.phase == :queued end)
    |> Enum.reduce(state, fn {operation_ref, _operation}, current_state ->
      start_thread(current_state, operation_ref)
    end)
  end

  defp finish_operation(state, operation_ref, result, options \\ []) do
    case Map.pop(state.operations, operation_ref) do
      {nil, _operations} ->
        state

      {operation, operations} ->
        Process.cancel_timer(operation.timer)
        Process.demonitor(operation.caller_monitor, [:flush])
        GenServer.reply(operation.from, result)

        cleanup = Keyword.get(options, :cleanup, :cancel)

        state = %{
          state
          | operations: operations,
            pending: detach_operation_requests(state.pending, operation_ref, operation, cleanup)
        }

        release_operation(state, operation, cleanup)
    end
  end

  defp abandon_operation(state, operation_ref) do
    case Map.pop(state.operations, operation_ref) do
      {nil, _operations} ->
        state

      {operation, operations} ->
        Process.cancel_timer(operation.timer)

        state = %{
          state
          | operations: operations,
            pending: detach_operation_requests(state.pending, operation_ref, operation, :cancel)
        }

        release_operation(state, operation, :cancel)
    end
  end

  defp release_operation(state, _operation, false), do: state

  defp release_operation(state, operation, :unsubscribe),
    do: unsubscribe_thread(state, operation.thread_id)

  defp release_operation(state, %{thread_id: nil}, :cancel), do: state

  defp release_operation(state, %{thread_id: thread_id, turn_id: nil}, :cancel),
    do: unsubscribe_thread(state, thread_id)

  defp release_operation(state, %{thread_id: thread_id, turn_id: turn_id}, :cancel) do
    interrupt_turn(state, thread_id, turn_id)
  end

  defp interrupt_turn(state, thread_id, turn_id) do
    case send_request(
           state,
           "turn/interrupt",
           %{"threadId" => thread_id, "turnId" => turn_id},
           {:interrupt, thread_id}
         ) do
      {:ok, state} -> state
      {:error, _reason, state} -> unsubscribe_thread(state, thread_id)
    end
  end

  defp unsubscribe_thread(state, nil), do: state

  defp unsubscribe_thread(state, thread_id) do
    case send_request(
           state,
           "thread/unsubscribe",
           %{"threadId" => thread_id},
           {:unsubscribe, thread_id}
         ) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp detach_operation_requests(pending, operation_ref, operation, :cancel) do
    pending
    |> Map.reject(fn {_id, tag} -> tag == {:list_models, operation_ref} end)
    |> Map.new(fn
      {id, {:start_thread, ^operation_ref}} -> {id, :orphan_thread}
      {id, {:start_turn, ^operation_ref}} -> {id, {:orphan_turn, operation.thread_id}}
      entry -> entry
    end)
  end

  defp detach_operation_requests(pending, operation_ref, _operation, _cleanup) do
    Map.reject(pending, fn {_id, tag} ->
      tag in [
        {:list_models, operation_ref},
        {:start_thread, operation_ref},
        {:start_turn, operation_ref}
      ]
    end)
  end

  defp fail_all_operations(state, reason) do
    Enum.reduce(Map.keys(state.operations), state, fn operation_ref, current_state ->
      finish_operation(current_state, operation_ref, {:error, reason}, cleanup: false)
    end)
  end

  defp transport_stopped(%{status: :disconnected} = state, _reason), do: state

  defp transport_stopped(state, reason) do
    state
    |> fail_all_operations({:codex_app_server_stopped, reason})
    |> Map.merge(%{port: nil, status: :disconnected, buffer: "", pending: %{}})
  end

  defp close_transport(%{port: port} = state) when is_port(port) do
    Port.close(port)
    %{state | port: nil, status: :disconnected, buffer: "", pending: %{}}
  catch
    :error, :badarg -> %{state | port: nil, status: :disconnected, buffer: "", pending: %{}}
  end

  defp close_transport(state),
    do: %{state | status: :disconnected, buffer: "", pending: %{}}

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp configured_timeout do
    Application.get_env(:codex_river, __MODULE__, [])[:timeout] || @default_timeout
  end

  defp requested_value_error?(error, field) do
    error
    |> inspect()
    |> String.downcase()
    |> String.contains?(field)
  end

  defp server_overloaded?(%{"codexErrorInfo" => "serverOverloaded"}), do: true

  defp server_overloaded?(%{"codexErrorInfo" => info}) when is_map(info) do
    info["type"] == "serverOverloaded" or info["kind"] == "serverOverloaded" or
      info["code"] == "serverOverloaded" or Map.has_key?(info, "serverOverloaded")
  end

  defp server_overloaded?(_error), do: false

  defp retry_with_another_model(state, operation_ref, overload_error) do
    case state.operations[operation_ref] do
      nil ->
        state

      operation ->
        current_model = operation.selected_model || operation.model

        with true <- operation.overload_model_switches < @max_overload_model_switches,
             {:ok, next_model, direction} <-
               next_overload_model(current_model, operation.overload_model_direction) do
          switch_number = operation.overload_model_switches + 1

          Logger.info(
            "Codex app-server model switch after overload: " <>
              "from=#{current_model} to=#{next_model} " <>
              "effort=#{operation.reasoning_effort || "default"} " <>
              "switch=#{switch_number}/#{@max_overload_model_switches}",
            previous_model: current_model,
            next_model: next_model,
            reasoning_effort: operation.reasoning_effort,
            overload_model_switch: switch_number
          )

          previous_thread_id = operation.thread_id

          operation = %{
            operation
            | phase: :queued,
              model: next_model,
              requested_reasoning_effort: operation.reasoning_effort,
              supported_reasoning_efforts: :unknown,
              selected_model: nil,
              thread_id: nil,
              turn_id: nil,
              overload_model_switches: switch_number,
              overload_model_direction: direction,
              content: "",
              usage: nil,
              agent_items: %{}
          }

          state
          |> put_in([Access.key(:operations), operation_ref], operation)
          |> unsubscribe_thread(previous_thread_id)
          |> start_thread(operation_ref)
        else
          _no_retry ->
            finish_operation(
              state,
              operation_ref,
              {:error, {:app_server_turn_failed, overload_error}},
              cleanup: :unsubscribe
            )
        end
    end
  end

  defp next_overload_model("gpt-5.6-sol", direction) when direction in [nil, :down],
    do: {:ok, "gpt-5.6-terra", :down}

  defp next_overload_model("gpt-5.6-terra", direction) when direction in [nil, :down],
    do: {:ok, "gpt-5.6-luna", :down}

  defp next_overload_model("gpt-5.6-luna", direction) when direction in [nil, :down],
    do: {:ok, "gpt-5.6-terra", :up}

  defp next_overload_model("gpt-5.6-terra", :up), do: {:ok, "gpt-5.6-sol", :up}
  defp next_overload_model(_model, _direction), do: :error

  defp supported_reasoning_efforts(%{"data" => models}, requested_model)
       when is_list(models) do
    case Enum.find(models, &model_matches?(&1, requested_model)) do
      nil -> :not_found
      model -> parse_reasoning_efforts(model)
    end
  end

  defp supported_reasoning_efforts(_result, _requested_model), do: :unknown

  defp model_matches?(model, requested_model)
       when is_map(model) and is_binary(requested_model) do
    model["model"] == requested_model or model["id"] == requested_model
  end

  defp model_matches?(_model, _requested_model), do: false

  defp parse_reasoning_efforts(%{"supportedReasoningEfforts" => options})
       when is_list(options) do
    Enum.reduce_while(options, {:ok, []}, fn
      %{"reasoningEffort" => effort}, {:ok, efforts}
      when is_binary(effort) and byte_size(effort) > 0 ->
        {:cont, {:ok, [effort | efforts]}}

      _option, _acc ->
        {:halt, :unknown}
    end)
    |> case do
      {:ok, efforts} -> {:ok, Enum.reverse(efforts)}
      :unknown -> :unknown
    end
  end

  defp parse_reasoning_efforts(_model), do: :unknown

  defp negotiate_reasoning_effort(state, operation_ref, supported) do
    operation = state.operations[operation_ref]
    requested = operation.requested_reasoning_effort
    effective = resolve_reasoning_effort(requested, supported)

    state
    |> put_in([Access.key(:operations), operation_ref, :supported_reasoning_efforts], supported)
    |> put_in([Access.key(:operations), operation_ref, :reasoning_effort], effective)
  end

  defp resolve_reasoning_effort(nil, _supported), do: nil

  defp resolve_reasoning_effort(requested, supported) when is_list(supported) do
    cond do
      requested in supported -> requested
      requested in ["none", "minimal"] and "low" in supported -> "low"
      true -> requested
    end
  end

  defp resolve_reasoning_effort(requested, :unknown), do: requested

  defp continue_after_thread_start(state, operation_ref) do
    case state.operations[operation_ref] do
      nil ->
        state

      %{requested_reasoning_effort: nil} ->
        start_turn(state, operation_ref)

      %{selected_model: selected_model} when is_binary(selected_model) and selected_model != "" ->
        request_model_capabilities(state, operation_ref)

      _operation ->
        start_turn(state, operation_ref)
    end
  end

  defp start_turn_if_active(state, operation_ref) do
    if state.operations[operation_ref] do
      start_turn(state, operation_ref)
    else
      state
    end
  end

  defp maybe_force_lowest_model(%{config: config}, model, reasoning_effort) do
    if config[:force_low] do
      if model != @lowest_model or reasoning_effort != @lowest_reasoning_effort do
        Logger.info(
          "Codex app-server forced model: " <>
            "from=#{model || "default"} to=#{@lowest_model} " <>
            "effort=#{reasoning_effort || "default"}->#{@lowest_reasoning_effort}",
          previous_model: model,
          next_model: @lowest_model,
          reasoning_effort: @lowest_reasoning_effort
        )
      end

      {@lowest_model, @lowest_reasoning_effort}
    else
      {model, reasoning_effort}
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
