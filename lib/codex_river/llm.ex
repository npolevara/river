defmodule CodexRiver.LLM do
  @moduledoc false

  @type message :: map()
  @type usage :: %{
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer()
        }
  @type completion :: %{
          required(:content) => String.t() | nil,
          required(:tool_calls) => [map()],
          required(:usage) => usage(),
          optional(:stop_reason) => String.t() | nil
        }

  @callback complete([message()], keyword()) :: {:ok, completion()} | {:error, term()}

  @spec complete([message()], keyword()) :: {:ok, completion()} | {:error, term()}
  def complete(messages, options) do
    requested_model = Keyword.fetch!(options, :model)

    options
    |> Keyword.put(:model, resolve_model(requested_model))
    |> then(&adapter().complete(messages, &1))
  end

  defp adapter, do: Application.fetch_env!(:codex_river, :llm_adapter)

  defp resolve_model(requested_model) do
    public_model = Application.fetch_env!(:codex_river, :public_model)

    if requested_model == public_model do
      Application.get_env(:codex_river, :codex_model)
    else
      :codex_river
      |> Application.get_env(:model_aliases, %{})
      |> Map.get(requested_model, requested_model)
    end
  end
end
