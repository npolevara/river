defmodule CodexRiver.OpenAI.Response do
  @moduledoc false

  alias CodexRiver.OpenAI.ResponseRequest

  def id, do: "resp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  def message_id, do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @spec response(ResponseRequest.t(), map(), String.t(), String.t(), integer()) :: map()
  def response(request, completion, id, message_id, created) do
    %{
      id: id,
      object: "response",
      created_at: created,
      completed_at: created,
      status: "completed",
      error: nil,
      incomplete_details: nil,
      instructions: request.instructions,
      max_output_tokens: nil,
      metadata: %{},
      model: request.model,
      output: [output_message(message_id, completion.content, "completed")],
      parallel_tool_calls: true,
      previous_response_id: nil,
      reasoning: reasoning(request),
      store: false,
      temperature: 1.0,
      text: %{format: %{type: "text"}},
      tool_choice: "auto",
      tools: [],
      top_p: 1.0,
      truncation: "disabled",
      usage: usage(completion.usage)
    }
  end

  def started_events(request, id, message_id, created) do
    initial_response = %{
      id: id,
      object: "response",
      created_at: created,
      completed_at: nil,
      status: "in_progress",
      error: nil,
      incomplete_details: nil,
      instructions: request.instructions,
      max_output_tokens: nil,
      metadata: %{},
      model: request.model,
      output: [],
      parallel_tool_calls: true,
      previous_response_id: nil,
      reasoning: reasoning(request),
      store: false,
      temperature: 1.0,
      text: %{format: %{type: "text"}},
      tool_choice: "auto",
      tools: [],
      top_p: 1.0,
      truncation: "disabled",
      usage: nil
    }

    [
      event("response.created", %{response: initial_response}, 0),
      event(
        "response.output_item.added",
        %{output_index: 0, item: output_message(message_id, "", "in_progress", [])},
        1
      ),
      event(
        "response.content_part.added",
        %{
          item_id: message_id,
          output_index: 0,
          content_index: 0,
          part: output_text("")
        },
        2
      )
    ]
  end

  def delta(message_id, text, sequence_number) do
    event(
      "response.output_text.delta",
      %{
        item_id: message_id,
        output_index: 0,
        content_index: 0,
        delta: text,
        logprobs: []
      },
      sequence_number
    )
  end

  def completed_events(request, completion, id, message_id, created, sequence_number) do
    text = completion.content
    output = output_message(message_id, text, "completed")
    response = response(request, completion, id, message_id, created)

    [
      event(
        "response.output_text.done",
        %{
          item_id: message_id,
          output_index: 0,
          content_index: 0,
          text: text,
          logprobs: []
        },
        sequence_number
      ),
      event(
        "response.content_part.done",
        %{
          item_id: message_id,
          output_index: 0,
          content_index: 0,
          part: output_text(text)
        },
        sequence_number + 1
      ),
      event(
        "response.output_item.done",
        %{output_index: 0, item: output},
        sequence_number + 2
      ),
      event("response.completed", %{response: response}, sequence_number + 3)
    ]
  end

  def error(error, sequence_number) do
    event("error", Map.take(error, [:message, :type, :param, :code]), sequence_number)
  end

  defp output_message(message_id, text, status, content \\ nil) do
    %{
      id: message_id,
      type: "message",
      status: status,
      role: "assistant",
      content: content || [output_text(text)]
    }
  end

  defp output_text(text),
    do: %{type: "output_text", text: text, annotations: [], logprobs: []}

  defp reasoning(request) do
    %{effort: request.reasoning.effort, mode: request.reasoning.mode, summary: nil}
  end

  defp usage(usage) do
    %{
      input_tokens: usage.prompt_tokens,
      input_tokens_details: %{cached_tokens: 0},
      output_tokens: usage.completion_tokens,
      output_tokens_details: %{reasoning_tokens: 0},
      total_tokens: usage.total_tokens
    }
  end

  defp event(type, payload, sequence_number) do
    data = payload |> Map.put(:type, type) |> Map.put(:sequence_number, sequence_number)
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end
end
