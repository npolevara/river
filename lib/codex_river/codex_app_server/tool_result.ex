defmodule CodexRiver.CodexAppServer.ToolResult do
  @moduledoc false

  @spec decode(String.t(), [map()]) :: %{content: String.t() | nil, tool_calls: [map()]}
  def decode(content, tools) when is_binary(content) and is_list(tools) do
    allowed_names = MapSet.new(tools, & &1.function.name)

    with {:ok, envelope} <- decode_json(content),
         {:ok, result} <- decode_envelope(envelope, allowed_names) do
      result
    else
      _error -> %{content: content, tool_calls: []}
    end
  end

  defp decode_json(content) do
    content
    |> String.trim()
    |> strip_code_fence()
    |> Jason.decode()
  end

  defp strip_code_fence("```json\n" <> content), do: strip_code_fence_end(content)
  defp strip_code_fence("```\n" <> content), do: strip_code_fence_end(content)
  defp strip_code_fence(content), do: content

  defp strip_code_fence_end(content) do
    content
    |> String.trim_trailing()
    |> String.trim_trailing("```")
    |> String.trim_trailing()
  end

  defp decode_envelope(%{"type" => "message", "content" => content}, _allowed_names)
       when is_binary(content) do
    {:ok, %{content: content, tool_calls: []}}
  end

  defp decode_envelope(%{"type" => "tool_calls", "tool_calls" => calls}, allowed_names)
       when is_list(calls) and calls != [] do
    decode_tool_calls(calls, allowed_names)
  end

  defp decode_envelope(_envelope, _allowed_names), do: :error

  defp decode_tool_calls(calls, allowed_names) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, parsed} ->
      case decode_tool_call(call, allowed_names) do
        {:ok, parsed_call} -> {:cont, {:ok, [parsed_call | parsed]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, %{content: nil, tool_calls: Enum.reverse(parsed)}}
      :error -> :error
    end
  end

  defp decode_tool_call(%{"name" => name, "arguments" => arguments}, allowed_names)
       when is_binary(name) and is_map(arguments) do
    if MapSet.member?(allowed_names, name) do
      {:ok,
       %{
         id: tool_call_id(),
         type: "function",
         function: %{name: name, arguments: Jason.encode!(arguments)}
       }}
    else
      :error
    end
  end

  defp decode_tool_call(_call, _allowed_names), do: :error

  defp tool_call_id do
    "call_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
