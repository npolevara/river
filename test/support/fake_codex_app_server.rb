#!/usr/bin/env ruby

require "json"

class FakeCodexAppServer
  PendingTurn = Struct.new(:message, :thread_id, :turn_id, keyword_init: true)

  def initialize(input: $stdin, output: $stdout)
    @input = input
    @output = output
    @output.sync = true
    @instance_id = Process.pid.to_s
    @initialized = false
    @next_thread = 1
    @next_turn = 1
    @next_approval = 1
    @threads = {}
    @pending_turns = {}
  end

  def run
    @input.each_line do |line|
      dispatch(JSON.parse(line))
    end
  end

  private

  def dispatch(message)
    case message["method"]
    when "initialize" then initialize_connection(message)
    when "initialized" then @initialized = true
    when "thread/start" then start_thread(message)
    when "turn/start" then start_turn(message)
    when "turn/interrupt" then interrupt_turn(message)
    when "thread/unsubscribe" then unsubscribe_thread(message)
    else handle_client_response(message)
    end
  end

  def initialize_connection(message)
    emit_result(
      message["id"],
      {
        "userAgent" => "fake-codex-app-server",
        "platformFamily" => "unix",
        "platformOs" => "test"
      }
    )
  end

  def start_thread(message)
    return emit_error(message["id"], -32_002, "Not initialized") unless @initialized

    params = message["params"]

    unless valid_thread_policy?(params)
      return emit_error(message["id"], -32_602, "Invalid thread policy")
    end

    if params["model"] == "missing-model"
      return emit_error(message["id"], -32_602, "Unknown model")
    end

    thread = build_thread(params)
    @threads[thread["id"]] = thread

    emit_result(
      message["id"],
      {
        "thread" => thread,
        "model" => thread["model"],
        "modelProvider" => "fake",
        "cwd" => params["cwd"],
        "approvalPolicy" => params["approvalPolicy"],
        "sandbox" => {"type" => params["sandbox"]},
        "approvalsReviewer" => "user"
      }
    )
    emit_notification("thread/started", "thread" => thread)
  end

  def valid_thread_policy?(params)
    params["ephemeral"] == true &&
      params["sandbox"] == "read-only" &&
      params["approvalPolicy"] == "never"
  end

  def build_thread(params)
    thread_id = "#{@instance_id}-thread-#{@next_thread}"
    @next_thread += 1

    {
      "id" => thread_id,
      "sessionId" => thread_id,
      "ephemeral" => params.fetch("ephemeral", false),
      "model" => params.fetch("model", "fake-model")
    }
  end

  def start_turn(message)
    params = message["params"]

    if params["effort"] == "unsupported"
      return emit_error(message["id"], -32_602, "Unsupported effort")
    end

    turn_id = "turn-#{@next_turn}"
    @next_turn += 1
    turn = {"id" => turn_id, "status" => "inProgress", "items" => [], "error" => nil}

    emit_result(message["id"], "turn" => turn)
    emit_notification(
      "turn/started",
      "threadId" => params["threadId"],
      "turn" => turn
    )
    request_approval(message, params["threadId"], turn_id)
  end

  def request_approval(message, thread_id, turn_id)
    approval_id = "approval-#{@next_approval}"
    @next_approval += 1
    @pending_turns[approval_id] = PendingTurn.new(
      message: message,
      thread_id: thread_id,
      turn_id: turn_id
    )

    emit(
      "id" => approval_id,
      "method" => "item/commandExecution/requestApproval",
      "params" => {
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => "command-#{turn_id}",
        "reason" => "fake approval",
        "command" => "echo fake"
      }
    )
  end

  def handle_client_response(message)
    pending_turn = @pending_turns.delete(message["id"])

    if pending_turn
      exit(9) unless message.dig("result", "decision") == "decline"

      finish_turn(pending_turn)
    elsif message.key?("id")
      emit_error(message["id"], -32_601, "Unknown fake method")
    end
  end

  def finish_turn(pending_turn)
    prompt = pending_turn.message["params"]["input"][0]["text"]
    effort = pending_turn.message["params"].fetch("effort", "medium")
    chunks = response_chunks(prompt, pending_turn, effort)
    item = agent_message(pending_turn.turn_id, chunks.join)

    emit_item_started(pending_turn, item)
    chunks.each { |chunk| emit_delta(pending_turn, item["id"], chunk) }
    emit_item_completed(pending_turn, item)
    emit_token_usage(pending_turn)
    emit_turn_completed(pending_turn, item)
  end

  def response_chunks(prompt, pending_turn, effort)
    case prompt
    when "with-commentary"
      emit_commentary(pending_turn)
      ["Final only"]
    when "report-instance"
      [@instance_id]
    when "report-thread"
      [pending_turn.thread_id]
    when "report-config"
      thread = @threads.fetch(pending_turn.thread_id)
      ["#{thread.fetch("model")}:#{effort}"]
    else
      default_response_chunks(prompt)
    end
  end

  def default_response_chunks(prompt)
    tool_role = prompt.include?('"role":"tool"')

    if prompt.include?("request-tool") && !tool_role
      [
        JSON.generate(
          "type" => "tool_calls",
          "tool_calls" => [
            {
              "name" => "run_shell_command",
              "arguments" => {"command" => "git log"}
            }
          ]
        )
      ]
    elsif tool_role
      [JSON.generate("type" => "message", "content" => "Tool result accepted")]
    else
      ["Codex: ", prompt]
    end
  end

  def emit_commentary(pending_turn)
    item = {
      "type" => "agentMessage",
      "id" => "commentary-#{pending_turn.turn_id}",
      "text" => "Internal progress",
      "phase" => "commentary"
    }

    emit_item_started(pending_turn, item)
    emit_delta(pending_turn, item["id"], item["text"])
    emit_item_completed(pending_turn, item)
  end

  def agent_message(turn_id, text)
    {
      "type" => "agentMessage",
      "id" => "item-#{turn_id}",
      "text" => text,
      "phase" => "final_answer"
    }
  end

  def emit_item_started(pending_turn, item)
    emit_notification(
      "item/started",
      "threadId" => pending_turn.thread_id,
      "turnId" => pending_turn.turn_id,
      "item" => item.merge("text" => ""),
      "startedAtMs" => 1
    )
  end

  def emit_delta(pending_turn, item_id, delta)
    emit_notification(
      "item/agentMessage/delta",
      "threadId" => pending_turn.thread_id,
      "turnId" => pending_turn.turn_id,
      "itemId" => item_id,
      "delta" => delta
    )
  end

  def emit_item_completed(pending_turn, item)
    emit_notification(
      "item/completed",
      "threadId" => pending_turn.thread_id,
      "turnId" => pending_turn.turn_id,
      "item" => item,
      "completedAtMs" => 2
    )
  end

  def emit_token_usage(pending_turn)
    usage = {
      "inputTokens" => 11,
      "cachedInputTokens" => 0,
      "outputTokens" => 3,
      "reasoningOutputTokens" => 0,
      "totalTokens" => 14
    }

    emit_notification(
      "thread/tokenUsage/updated",
      "threadId" => pending_turn.thread_id,
      "turnId" => pending_turn.turn_id,
      "tokenUsage" => {
        "last" => usage,
        "total" => usage,
        "modelContextWindow" => 1000
      }
    )
  end

  def emit_turn_completed(pending_turn, item)
    emit_notification(
      "turn/completed",
      "threadId" => pending_turn.thread_id,
      "turn" => {
        "id" => pending_turn.turn_id,
        "status" => "completed",
        "items" => [item],
        "error" => nil
      }
    )
  end

  def interrupt_turn(message)
    params = message["params"]
    emit_result(message["id"], {})
    emit_notification(
      "turn/completed",
      "threadId" => params["threadId"],
      "turn" => {
        "id" => params["turnId"],
        "status" => "interrupted",
        "items" => [],
        "error" => nil
      }
    )
  end

  def unsubscribe_thread(message)
    @threads.delete(message["params"]["threadId"])
    emit_result(message["id"], {})
  end

  def emit_result(id, result)
    emit("id" => id, "result" => result)
  end

  def emit_error(id, code, message)
    emit("id" => id, "error" => {"code" => code, "message" => message})
  end

  def emit_notification(method, params)
    emit("method" => method, "params" => params)
  end

  def emit(message)
    @output.puts(JSON.generate(message))
  end
end

if $PROGRAM_NAME == __FILE__
  Signal.trap("PIPE", "DEFAULT") if Signal.list.key?("PIPE")
  FakeCodexAppServer.new.run
end
