defmodule Rho.Models do
  @moduledoc """
  The models rho can call right now (like omp's `/models`): the static
  catalog filtered to the providers that have a credential (`Rho.Auth`).

    * Claude (`anthropic:`), OpenAI (`openai:`) and Gemini (`google:`):
      llm_db's models (the catalog req_llm resolves them through; rho
      ships it trimmed to these providers, `Rho.LLMCatalog`), retired and
      deprecated ones left out. Claude: newest first within Opus, Sonnet,
      Haiku, then the rest. OpenAI and Gemini: the chat models that take
      tools, newest release first.
    * ChatGPT (`openai_codex:`): the models the Codex backend accepts
      for a ChatGPT account, which llm_db doesn't list: Codex's own list,
      fetched and kept by `Rho.Models.Codex`, in Codex's order (the first
      is the sign-in's default).
  """

  alias Rho.Auth
  alias Rho.Models.Codex

  @type model :: %{
          provider: Auth.provider(),
          spec: String.t(),
          name: String.t(),
          context: pos_integer() | nil
        }

  @doc """
  `[{provider, signed_in?, models}]` for every provider, in `Rho.Auth.providers/0`
  order; a provider without a credential has no models.
  """
  @spec by_provider(map()) :: [{Auth.provider(), boolean(), [model()]}]
  def by_provider(status \\ Auth.status()) do
    for provider <- Auth.providers() do
      signed_in = match?(%{signed_in: true}, status[provider])
      {provider, signed_in, if(signed_in, do: catalog(provider), else: [])}
    end
  end

  @doc """
  Every model of `provider` in the catalog, whether signed in or not.
  ChatGPT's is the sign-in's current list (`Rho.Models.Codex`), asked for
  again in the background when it is stale, so a picker should ask each
  time it opens rather than keep it; `opts` (ChatGPT's only): whose list,
  `:data_dir` and `:credential` (default the node's sign-in, `Rho.Auth`).
  """
  @spec catalog(Auth.provider(), keyword()) :: [model()]
  def catalog(provider, opts \\ [])

  def catalog(:anthropic, _opts) do
    :anthropic
    |> current()
    |> Enum.map(&model(:anthropic, &1))
    |> Enum.sort_by(&claude_order/1)
  end

  def catalog(:openai_codex, opts) do
    opts = Keyword.take(opts, [:data_dir, :credential])
    Codex.refresh_async(opts)

    for m <- Codex.models(opts),
        do: %{
          provider: :openai_codex,
          spec: "openai_codex:" <> m.id,
          name: m.name,
          context: m.context
        }
  end

  def catalog(provider, _opts) when provider in [:openai, :google] do
    provider
    |> current()
    |> Enum.filter(&agentic?/1)
    |> Enum.sort_by(&{to_string(&1.release_date), &1.id}, :desc)
    |> Enum.map(&model(provider, &1))
  end

  def catalog(_other, _opts), do: []

  defp current(provider),
    do: provider |> LLMDB.models() |> Enum.reject(&(&1.retired || &1.deprecated))

  # A chat model that takes tool definitions (the loop always sends them),
  # served by the streaming chat API: not a realtime / live (websocket)
  # model, a deep-research agent or a computer-use one.
  defp agentic?(m) do
    caps = m.capabilities || %{}

    caps[:chat] == true and get_in(caps, [:tools, :enabled]) == true and
      not Regex.match?(other_api(), m.id)
  end

  defp other_api, do: Regex.compile!("realtime|-live|deep-research|computer-use")

  defp model(provider, m) do
    %{
      provider: provider,
      spec: "#{provider}:" <> m.id,
      name: m.name || m.id,
      context: get_in(m, [Access.key(:limits), :context])
    }
  end

  @doc """
  The model a saved `spec` runs as: itself, or, for a ChatGPT model the
  sign-in no longer accepts (`Rho.Models.Codex.replacement/2`, `opts` its
  `:data_dir`), the sign-in's default. A loop makes the same move when a
  run starts, with a notice.
  """
  @spec resolve(String.t(), keyword()) :: String.t()
  def resolve(spec, opts \\ []) when is_binary(spec), do: Codex.replacement(spec, opts) || spec

  @doc """
  Whether two model specs name the same model, ignoring a dated snapshot
  suffix (`claude-haiku-4-5` is `claude-haiku-4-5-20251001`).
  """
  @spec same?(String.t(), String.t()) :: boolean()
  def same?(a, b), do: undated(a) == undated(b)

  defp undated(spec), do: String.replace(spec, ~r/-\d{8}$/, "")

  @doc """
  What `spec` takes as input (`:text`, `:image`, `:pdf`, ...): llm_db's
  `modalities.input`, looked up once per spec and kept (the loop asks on
  every request). Every model on the Codex backend takes text and pictures
  (omp's catalog); a Claude model llm_db doesn't know (a custom id) takes
  pictures and PDFs like every Claude; anything else unknown, text only.
  """
  @spec inputs(String.t()) :: [atom()]
  def inputs(spec) do
    key = {__MODULE__, :inputs, spec}

    case :persistent_term.get(key, nil) do
      nil ->
        inputs = lookup_inputs(spec)
        :persistent_term.put(key, inputs)
        inputs

      inputs ->
        inputs
    end
  end

  @doc "Does `spec` take pictures?"
  @spec images?(String.t()) :: boolean()
  def images?(spec), do: :image in inputs(spec)

  defp lookup_inputs("openai_codex:" <> _id), do: [:text, :image]

  defp lookup_inputs(spec) do
    case LLMDB.model(spec) do
      {:ok, %{modalities: %{input: [_ | _] = input}}} -> input
      _ -> if String.starts_with?(spec, "anthropic:"), do: [:text, :image, :pdf], else: [:text]
    end
  end

  # Opus, Sonnet, Haiku, then the rest; newest version first in each.
  defp claude_order(%{name: name}) do
    family =
      cond do
        name =~ ~r/opus/i -> 0
        name =~ ~r/sonnet/i -> 1
        name =~ ~r/haiku/i -> 2
        true -> 3
      end

    # 5 is 5.0.0, so 5.5 sorts above it.
    version =
      ~r/\d+/
      |> Regex.scan(name)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Kernel.++([0, 0, 0])
      |> Enum.take(3)
      |> Enum.map(&(-&1))

    {family, version, name}
  end
end
