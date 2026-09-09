defmodule CodexRiver.OpenAI.ResponseRequest do
  @moduledoc false

  @input_roles ~w(system developer user assistant)
  @reasoning_efforts ~w(none minimal low medium high xhigh max)
  @reasoning_modes ~w(standard pro)
  @text_part_types ~w(input_text output_text text)

  @type reasoning :: %{required(:effort) => String.t() | nil, required(:mode) => String.t() | nil}
  @type t :: %__MODULE__{
          model: String.t(),
          messages: [CodexRiver.LLM.message()],
          instructions: String.t() | nil,
          reasoning: reasoning(),
          stream: boolean()
        }

  defstruct [:model, :messages, :instructions, :reasoning, stream: false]

  @spec parse(map()) :: {:ok, t()} | {:error, map()}
  def parse(params) when is_map(params) do
    with {:ok, model} <- parse_model(params),
         {:ok, input_messages} <- parse_input(params),
         {:ok, instructions} <- parse_instructions(params),
         {:ok, reasoning} <- parse_reasoning(params),
         {:ok, stream} <- parse_stream(params),
         :ok <- reject_stateful_input(params) do
      {:ok,
       %__MODULE__{
         model: model,
         messages: prepend_instructions(input_messages, instructions),
         instructions: instructions,
         reasoning: reasoning,
         stream: stream
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

  defp parse_input(%{"input" => input}) when is_binary(input),
    do: {:ok, [%{role: "user", content: input}]}

  defp parse_input(%{"input" => input}) when is_list(input) and input != [] do
    input
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, messages} ->
      case parse_input_item(item, index) do
        {:ok, message} -> {:cont, {:ok, [message | messages]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp parse_input(_params),
    do: error("'input' is required and must be a string or non-empty array", "input")

  defp parse_input_item(%{"role" => role, "content" => content}, index)
       when role in @input_roles do
    case text_content(content) do
      {:ok, text} -> {:ok, %{role: role, content: text}}
      :error -> error("Only text response input is supported", "input[#{index}].content")
    end
  end

  defp parse_input_item(%{"role" => role}, index) when is_binary(role),
    do: error("Unsupported input role '#{role}'", "input[#{index}].role")

  defp parse_input_item(_item, index),
    do: error("Each input item must contain string 'role' and text 'content'", "input[#{index}]")

  defp text_content(content) when is_binary(content), do: {:ok, content}

  defp text_content(content) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => type, "text" => text}, {:ok, parts}
      when type in @text_part_types and is_binary(text) ->
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

  defp parse_instructions(params) do
    case Map.get(params, "instructions") do
      nil -> {:ok, nil}
      instructions when is_binary(instructions) -> {:ok, instructions}
      _instructions -> error("'instructions' must be a string", "instructions")
    end
  end

  defp parse_reasoning(params) do
    case Map.get(params, "reasoning", %{}) do
      reasoning when is_map(reasoning) ->
        with {:ok, effort} <- parse_reasoning_effort(reasoning),
             {:ok, mode} <- parse_reasoning_mode(reasoning) do
          {:ok, %{effort: effort, mode: mode}}
        end

      _reasoning ->
        error("'reasoning' must be an object", "reasoning")
    end
  end

  defp parse_reasoning_effort(reasoning) do
    case Map.get(reasoning, "effort") do
      nil -> {:ok, nil}
      effort when effort in @reasoning_efforts -> {:ok, effort}
      _effort -> error("Unsupported reasoning effort", "reasoning.effort")
    end
  end

  defp parse_reasoning_mode(reasoning) do
    case Map.get(reasoning, "mode") do
      nil -> {:ok, nil}
      mode when mode in @reasoning_modes -> {:ok, mode}
      _mode -> error("Unsupported reasoning mode", "reasoning.mode")
    end
  end

  defp parse_stream(params) do
    case Map.get(params, "stream", false) do
      stream when is_boolean(stream) -> {:ok, stream}
      _stream -> error("'stream' must be a boolean", "stream")
    end
  end

  defp reject_stateful_input(%{"previous_response_id" => id}) when not is_nil(id),
    do:
      error(
        "'previous_response_id' is not supported by this local gateway",
        "previous_response_id"
      )

  defp reject_stateful_input(_params), do: :ok

  defp prepend_instructions(messages, nil), do: messages

  defp prepend_instructions(messages, instructions),
    do: [%{role: "developer", content: instructions} | messages]

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
