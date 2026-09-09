defmodule CodexRiver.OpenAI.ChatCompletionRequest do
  @moduledoc false

  @roles ~w(system developer user assistant tool function)
  @reasoning_efforts ~w(none minimal low medium high xhigh max)

  @type t :: %__MODULE__{
          model: String.t(),
          messages: [CodexRiver.LLM.message()],
          reasoning_effort: String.t() | nil,
          tools: [map()],
          tool_choice: String.t() | map(),
          stream: boolean(),
          include_usage: boolean()
        }

  defstruct [
    :model,
    :messages,
    :reasoning_effort,
    tools: [],
    tool_choice: "none",
    stream: false,
    include_usage: false
  ]

  @spec parse(map()) :: {:ok, t()} | {:error, map()}
  def parse(params) when is_map(params) do
    with {:ok, model} <- parse_model(params),
         {:ok, messages} <- parse_messages(params),
         {:ok, stream} <- parse_stream(params),
         {:ok, reasoning_effort} <- parse_reasoning_effort(params),
         {:ok, tools} <- parse_tools(params),
         {:ok, tool_choice} <- parse_tool_choice(params, tools),
         :ok <- validate_single_choice(params) do
      {:ok,
       %__MODULE__{
         model: model,
         messages: messages,
         reasoning_effort: reasoning_effort,
         tools: tools,
         tool_choice: tool_choice,
         stream: stream,
         include_usage: include_usage?(params, stream)
       }}
    end
  end

  defp parse_model(%{"model" => model}) when is_binary(model) do
    case String.trim(model) do
      "" -> error("'model' must not be empty", "model")
      model -> {:ok, model}
    end
  end

  defp parse_model(_params), do: error("'model' is required and must be a string", "model")

  defp parse_messages(%{"messages" => messages}) when is_list(messages) and messages != [] do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, parsed} ->
      case parse_message(message, index) do
        {:ok, parsed_message} -> {:cont, {:ok, [parsed_message | parsed]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_messages(_params),
    do: error("'messages' is required and must be a non-empty array", "messages")

  defp parse_message(%{"role" => "assistant"} = message, index) do
    with {:ok, content} <- optional_text_content(message["content"]),
         {:ok, tool_calls} <- parse_message_tool_calls(message, index),
         :ok <- validate_assistant_message(content, tool_calls, index) do
      {:ok, %{role: "assistant", content: content, tool_calls: tool_calls}}
    end
  end

  defp parse_message(%{"role" => "tool", "content" => content} = message, index) do
    with {:ok, text} <- required_text_content(content, index),
         tool_call_id when is_binary(tool_call_id) and tool_call_id != "" <-
           message["tool_call_id"] do
      {:ok, %{role: "tool", content: text, tool_call_id: tool_call_id}}
    else
      {:error, _error} = error -> error
      _tool_call_id -> error("Tool messages require 'tool_call_id'", "messages[#{index}]")
    end
  end

  defp parse_message(%{"role" => role, "content" => content}, index) when role in @roles do
    case text_content(content) do
      {:ok, text} -> {:ok, %{role: role, content: text}}
      :error -> error("Only text message content is supported", "messages[#{index}].content")
    end
  end

  defp parse_message(%{"role" => role}, index) when is_binary(role),
    do: error("Unsupported message role '#{role}'", "messages[#{index}].role")

  defp parse_message(_message, index),
    do: error("Each message must contain string 'role' and text 'content'", "messages[#{index}]")

  defp text_content(content) when is_binary(content), do: {:ok, content}

  defp text_content(content) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, parts} when is_binary(text) ->
        {:cont, {:ok, [text | parts]}}

      _part, _accumulator ->
        {:halt, :error}
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join()}
      :error -> :error
    end
  end

  defp text_content(_content), do: :error

  defp optional_text_content(nil), do: {:ok, nil}
  defp optional_text_content(content), do: text_content(content)

  defp required_text_content(content, index) do
    case text_content(content) do
      {:ok, text} -> {:ok, text}
      :error -> error("Only text message content is supported", "messages[#{index}].content")
    end
  end

  defp parse_message_tool_calls(%{"tool_calls" => tool_calls}, index) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool_call, tool_index}, {:ok, parsed} ->
      case parse_message_tool_call(tool_call, index, tool_index) do
        {:ok, parsed_call} -> {:cont, {:ok, [parsed_call | parsed]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_message_tool_calls(_message, _index), do: {:ok, []}

  defp parse_message_tool_call(
         %{
           "id" => id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => arguments}
         },
         _message_index,
         _tool_index
       )
       when is_binary(id) and id != "" and is_binary(name) and name != "" and
              (is_binary(arguments) or is_map(arguments)) do
    {:ok,
     %{
       id: id,
       type: "function",
       function: %{name: name, arguments: arguments}
     }}
  end

  defp parse_message_tool_call(_tool_call, message_index, tool_index),
    do:
      error(
        "Invalid assistant tool call",
        "messages[#{message_index}].tool_calls[#{tool_index}]"
      )

  defp validate_assistant_message(nil, [], index),
    do: error("Assistant messages require content or tool calls", "messages[#{index}]")

  defp validate_assistant_message(_content, _tool_calls, _index), do: :ok

  defp parse_stream(params) do
    case Map.get(params, "stream", false) do
      stream when is_boolean(stream) -> {:ok, stream}
      _stream -> error("'stream' must be a boolean", "stream")
    end
  end

  defp parse_reasoning_effort(params) do
    case Map.get(params, "reasoning_effort") do
      nil -> {:ok, nil}
      effort when effort in @reasoning_efforts -> {:ok, effort}
      _effort -> error("Unsupported reasoning effort", "reasoning_effort")
    end
  end

  defp parse_tools(params) do
    case Map.get(params, "tools", []) do
      tools when is_list(tools) -> parse_tool_list(tools)
      _tools -> error("'tools' must be an array", "tools")
    end
  end

  defp parse_tool_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool, index}, {:ok, parsed} ->
      case parse_tool(tool, index) do
        {:ok, parsed_tool} -> {:cont, {:ok, [parsed_tool | parsed]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_tool(%{"type" => "function", "function" => function}, index)
       when is_map(function) do
    name = function["name"]
    description = Map.get(function, "description", "")
    parameters = Map.get(function, "parameters", %{"type" => "object", "properties" => %{}})

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        error("Function tools require a non-empty name", "tools[#{index}].function.name")

      not is_binary(description) ->
        error(
          "Function tool description must be a string",
          "tools[#{index}].function.description"
        )

      not is_map(parameters) ->
        error("Function tool parameters must be an object", "tools[#{index}].function.parameters")

      true ->
        {:ok,
         %{
           type: "function",
           function: %{
             name: String.trim(name),
             description: description,
             parameters: parameters
           }
         }}
    end
  end

  defp parse_tool(_tool, index),
    do: error("Only function tools are supported", "tools[#{index}]")

  defp parse_tool_choice(params, tools) do
    choice = Map.get(params, "tool_choice", if(tools == [], do: "none", else: "auto"))

    case choice do
      choice when choice in ["none", "auto", "required"] ->
        validate_tool_choice(choice, tools)

      %{"type" => "function", "function" => %{"name" => name}}
      when is_binary(name) and name != "" ->
        if Enum.any?(tools, &(&1.function.name == name)) do
          {:ok, %{type: "function", function: %{name: name}}}
        else
          error("tool_choice references an unknown function", "tool_choice")
        end

      _choice ->
        error("Unsupported tool choice", "tool_choice")
    end
  end

  defp validate_tool_choice("none", _tools), do: {:ok, "none"}
  defp validate_tool_choice(_choice, []), do: error("tool_choice requires tools", "tool_choice")
  defp validate_tool_choice(choice, _tools), do: {:ok, choice}

  defp validate_single_choice(params) do
    case Map.get(params, "n", 1) do
      1 -> :ok
      _n -> error("Only n=1 is supported", "n")
    end
  end

  defp include_usage?(%{"stream_options" => %{"include_usage" => true}}, true), do: true
  defp include_usage?(_params, _stream), do: false

  defp error(message, param) do
    {:error,
     %{
       message: message,
       type: "invalid_request_error",
       param: param,
       code: nil,
       status: 400
     }}
  end
end
