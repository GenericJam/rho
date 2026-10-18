defmodule Rho.Tools.Consult do
  @moduledoc """
  Tool `ask_model`: the lead model asks another model (`Rho.Consult`) and
  gets its answer back: a critique of its own work (purpose
  `"critique"`), a second opinion, or anything it would ask a colleague.
  Not one of the built-in tools: a host offers it by adding it to its
  tools (`Rho.Supervisor`'s `:tools`, or a loop's).

  `model` must be one the host allows (`:consult_models`, `Rho.Config`)
  whose provider is signed in (`Rho.Consult.allowed/1`); a refusal names
  the ones that may be asked. The schema lists the host's allow-list as
  `model`'s `enum` when it sets one; the sign-in is checked when the tool
  runs (the declaration is read in the loop's process, where the
  credential store isn't).

  The consult is the calling loop's (`ctx.loop`): its events go to the
  loop's subscribers with this call's id (`call_id`), its usage is
  recorded in the session, and stopping the loop stops it. The answer goes
  back to the lead as `"<model> (<purpose>):"` and the text; the details
  (`tool_execution_end`, `Rho.ToolRunner`) are `%{model, purpose, usage}`,
  for a host that draws the answer by purpose.
  """
  @behaviour Rho.Tool

  alias Rho.Consult

  @impl true
  def name, do: "ask_model"

  @impl true
  def description do
    "Ask another AI model and get its answer back: a critique of your work (purpose " <>
      "\"critique\": it pushes back; then fix what it got right and keep, with your reasons, " <>
      "what it got wrong), a second opinion, or anything you'd ask a colleague. It sees only " <>
      "`prompt` (and with include_conversation, this conversation so far), none of your " <>
      "tools: give it what it needs. It costs tokens like a reply of yours. " <> models_line()
  end

  defp models_line do
    case Rho.Config.consult_models() do
      [_ | _] = models ->
        "Models: " <> Enum.join(models, ", ") <> "."

      _ ->
        "`model` is a model id such as google:gemini-3.1-pro-preview; asking one that isn't " <>
          "available answers with the ones that are."
    end
  end

  @impl true
  def parameter_schema do
    model = %{"type" => "string", "description" => "The model to ask (provider:model)."}

    model =
      case Rho.Config.consult_models() do
        [_ | _] = models -> Map.put(model, "enum", models)
        _ -> model
      end

    %{
      "type" => "object",
      "properties" => %{
        "model" => model,
        "purpose" => %{
          "type" => "string",
          "description" =>
            ~s|"critique" (pushback on your work), "second_opinion", or a few words on | <>
              ~s|why you ask. Default "second_opinion".|
        },
        "prompt" => %{
          "type" => "string",
          "description" => "What to ask, complete in itself (the work to review, the question)."
        },
        "include_conversation" => %{
          "type" => "boolean",
          "description" => "Send this conversation so far as well. Default false."
        }
      },
      "required" => ["model", "prompt"],
      "additionalProperties" => false
    }
  end

  # A thinking model's long answer, possibly with tool calls of its own.
  @impl true
  def timeout_ms, do: 10 * 60_000

  @impl true
  def run(args, ctx) do
    with {:ok, model} <- text(args, "model"),
         {:ok, prompt} <- text(args, "prompt"),
         :ok <- Consult.allowed(model) do
      purpose = purpose(args["purpose"])

      opts =
        [purpose: purpose, call_id: ctx[:call_id], data_dir: ctx[:data_dir]] ++
          case ctx[:loop] do
            nil -> []
            loop -> [loop: loop, include_conversation: args["include_conversation"] == true]
          end

      case Consult.run(model, prompt, opts) do
        {:ok, answer} ->
          {:ok,
           {:details, "#{model} (#{purpose}):\n\n#{answer.text}",
            %{model: model, purpose: purpose, usage: answer.usage}}}

        {:error, error} ->
          {:error, Consult.describe(error)}
      end
    end
  end

  defp text(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _ -> {:error, "`#{key}` must be a non-empty string"}
    end
  end

  defp purpose(p) when is_binary(p) and p != "", do: String.trim(p)
  defp purpose(_), do: "second_opinion"
end
