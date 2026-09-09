defmodule CodexRiver.OpenAI.ChatCompletion do
  @moduledoc false

  alias CodexRiver.OpenAI.ChatCompletionRequest

  def id, do: "chatcmpl-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @spec response(ChatCompletionRequest.t(), map(), String.t(), integer()) :: map()
  def response(request, completion, id, created) do
    %{
      id: id,
      object: "chat.completion",
      created: created,
      model: request.model,
      choices: [
        %{
          index: 0,
          message: response_message(completion),
          logprobs: nil,
          finish_reason: finish_reason(completion)
        }
      ],
      usage: completion.usage
    }
  end

  def role_chunk(request, id, created),
    do: chunk(request, id, created, %{role: "assistant", content: ""}, nil)

  def content_chunk(request, id, created, content),
    do: chunk(request, id, created, %{content: content}, nil)

  def tool_calls_chunk(request, id, created, tool_calls) do
    streamed_calls =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {tool_call, index} -> Map.put(tool_call, :index, index) end)

    chunk(request, id, created, %{tool_calls: streamed_calls}, nil)
  end

  def stop_chunk(request, id, created, completion),
    do: chunk(request, id, created, %{}, finish_reason(completion))

  def usage_chunk(request, id, created, usage) do
    sse(%{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: request.model,
      choices: [],
      usage: usage
    })
  end

  def done, do: "data: [DONE]\n\n"
  def error(error), do: sse(%{error: Map.take(error, [:message, :type, :param, :code])})

  defp chunk(request, id, created, delta, finish_reason) do
    sse(%{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: request.model,
      choices: [
        %{index: 0, delta: delta, logprobs: nil, finish_reason: finish_reason}
      ]
    })
  end

  defp sse(value), do: "data: #{Jason.encode!(value)}\n\n"

  defp response_message(%{tool_calls: [_first | _rest] = tool_calls}),
    do: %{role: "assistant", content: nil, refusal: nil, tool_calls: tool_calls}

  defp response_message(completion),
    do: %{role: "assistant", content: completion.content, refusal: nil}

  defp finish_reason(%{tool_calls: [_first | _rest]}), do: "tool_calls"
  defp finish_reason(%{stop_reason: "max_tokens"}), do: "length"
  defp finish_reason(_completion), do: "stop"
end
