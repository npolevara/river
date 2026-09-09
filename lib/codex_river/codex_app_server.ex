defmodule CodexRiver.CodexAppServer do
  @moduledoc false

  @behaviour CodexRiver.LLM

  alias CodexRiver.CodexAppServer.Client
  alias CodexRiver.CodexAppServer.Prompt
  alias CodexRiver.CodexAppServer.ToolResult

  @impl true
  def complete(messages, options) do
    tool_options = Keyword.take(options, [:tools, :tool_choice])

    messages
    |> Prompt.render(tool_options)
    |> Client.complete(options)
    |> normalize_result(tool_options)
  end

  defp normalize_result({:ok, result}, options) do
    decoded = decode_tool_result(result.content, options)

    {:ok,
     %{
       content: decoded.content,
       tool_calls: decoded.tool_calls,
       usage: normalize_usage(result.usage),
       stop_reason: result.stop_reason
     }}
  end

  defp normalize_result(error, _options), do: error

  defp decode_tool_result(content, options) do
    case Keyword.get(options, :tools, []) do
      [] -> %{content: content, tool_calls: []}
      tools -> ToolResult.decode(content, tools)
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    input_tokens = non_negative_integer(usage["inputTokens"])
    output_tokens = non_negative_integer(usage["outputTokens"])

    %{
      prompt_tokens: input_tokens,
      completion_tokens: output_tokens,
      total_tokens: non_negative_integer(usage["totalTokens"], input_tokens + output_tokens)
    }
  end

  defp normalize_usage(_usage),
    do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp non_negative_integer(value, default \\ 0)
  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default
end
