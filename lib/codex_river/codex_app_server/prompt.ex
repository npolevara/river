defmodule CodexRiver.CodexAppServer.Prompt do
  @moduledoc false

  @spec render([CodexRiver.LLM.message()], keyword()) :: String.t()
  def render(messages, options \\ []) do
    case Keyword.get(options, :tools, []) do
      [] -> render_without_tools(messages)
      tools -> render_with_tools(messages, tools, options)
    end
  end

  defp render_without_tools([%{role: "user", content: content}]), do: content

  defp render_without_tools(messages) do
    transcript = Enum.map(messages, &transcript_message/1)

    """
    Answer the final message in the following chat transcript. Follow system and developer messages as instructions, preserve the conversation context, and return only the assistant's answer without role labels.

    #{Jason.encode!(transcript)}
    """
  end

  defp render_with_tools(messages, tools, options) do
    transcript = Enum.map(messages, &transcript_message/1)
    tool_choice = Keyword.get(options, :tool_choice, "auto")

    """
    Produce the next assistant turn for the transcript below. The client, not you, owns and executes the listed functions.

    Rules:
    - If the request requires inspecting files, running a command, searching, fetching data, or any other listed function, request that function now. Do not merely say that you will do it.
    - Never claim that a function ran unless the transcript contains its matching tool result.
    - Follow tool_choice exactly. "required" requires at least one call; "none" forbids calls; "auto" lets you choose. A named choice requires that function.
    - Return exactly one JSON object, without markdown or commentary.
    - For a normal answer return: {"type":"message","content":"your answer"}
    - To call functions return: {"type":"tool_calls","tool_calls":[{"name":"function_name","arguments":{}}]}
    - Function arguments must be a JSON object that satisfies the function's parameter schema. You may request multiple independent functions in one turn.

    tool_choice:
    #{Jason.encode!(tool_choice)}

    tools:
    #{Jason.encode!(tools)}

    transcript:
    #{Jason.encode!(transcript)}
    """
  end

  defp transcript_message(message) do
    message
    |> Map.take([:role, :content, :tool_calls, :tool_call_id, :name])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
