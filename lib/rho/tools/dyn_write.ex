defmodule Rho.Tools.DynWrite do
  @moduledoc "Core tool: create or overwrite a staged Dyn source file (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Dyn.Config
  alias Rho.Tools.DynTool

  @impl true
  def name, do: "dyn_write"

  @impl true
  def description do
    "Create or overwrite a source file of your Dyn layer in staging (Elixir, " <>
      "`defmodule #{Config.namespace_name()}.<Name>`). Nothing runs until you " <>
      "dyn_propose and the human approves."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => DynTool.path_schema(),
        "content" => %{"type" => "string", "description" => "The whole file."}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"path" => path, "content" => content}, ctx)
      when is_binary(path) and is_binary(content) do
    case Dyn.stage_put(path, content, DynTool.keeper(ctx)) do
      :ok -> {:ok, "Wrote #{path} (#{content |> String.split("\n") |> length()} lines)."}
      {:error, reason} -> DynTool.error(reason, path)
    end
  end

  def run(_args, _ctx), do: {:error, "`path` and `content` are required"}

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      with :ok <-
             DynTool.expect(
               run(%{"path" => "w.ex", "content" => "a\nb"}, ctx),
               &(&1 == {:ok, "Wrote w.ex (2 lines)."})
             ),
           :ok <- DynTool.expect(Dyn.stage_read("w.ex", ctx.dyn), &(&1 == {:ok, "a\nb"})) do
        DynTool.expect(
          run(%{"path" => "../w.ex", "content" => ""}, ctx),
          &match?({:error, _}, &1)
        )
      end
    end)
  end
end
