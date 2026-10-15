defmodule Rho.Tools.DynCopy do
  @moduledoc """
  Core tool: copy a staged Dyn source file to a new path under a new module
  name (see `Rho.Tools.DynTool`).

  It exists for speed. Starting a screen from a library widget by retyping
  it costs a whole file of output tokens; a copy costs one call, and the
  reply is the new file numbered as `dyn_read` shows it, so the next step
  is `dyn_edit` straight away.

  The rename is textual: every whole occurrence of the file's first
  module's full name, `Old` and `Old.Sub` alike, becomes the new one. A
  name that merely starts with it (`OldOther`) is left alone.
  """
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Dyn.Config
  alias Rho.Tools.DynRead
  alias Rho.Tools.DynTool

  @shown 250

  @impl true
  def name, do: "dyn_copy"

  @impl true
  def description do
    "Copy a staged Dyn file to a new path under a new module name, and show the copy with " <>
      "line numbers, ready for dyn_edit. Use it to start a screen from a library widget " <>
      "or from any of your files: it is far " <>
      "faster than writing the same code again with dyn_write. `module` defaults to one " <>
      "derived from `to` (screens/date_slider.ex: #{module_for("screens/date_slider.ex")})."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "from" => %{
          "type" => "string",
          "description" => "The staged file to copy, e.g. `screens/notes.ex`."
        },
        "to" => %{
          "type" => "string",
          "description" => "The new file's path (it must not exist yet), e.g. `screens/memo.ex`."
        },
        "module" => %{
          "type" => "string",
          "description" =>
            "The new module's name, `#{Config.namespace_name()}.*`. Default: derived from `to`."
        }
      },
      "required" => ["from", "to"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"from" => from, "to" => to} = args, ctx) when is_binary(from) and is_binary(to) do
    keeper = DynTool.keeper(ctx)

    with {:ok, new} <- new_module(args["module"], to),
         {:ok, source} <- read(from, keeper),
         {:ok, old} <- top_module(source, from),
         copy = rename(source, old, new),
         :ok <- put_new(to, copy, keeper) do
      {:ok, header(from, to, new, copy) <> "\n\n" <> listing(to, ctx)}
    end
  end

  def run(_args, _ctx), do: {:error, "`from` and `to` are required"}

  @doc """
  The module name for a staged path: `screens/date_slider.ex` is
  `Dyn.Screens.DateSlider` (in the namespace, `Rho.Dyn.Config`).
  """
  @spec module_for(String.t()) :: String.t()
  def module_for(path) do
    parts = path |> String.replace_suffix(".ex", "") |> String.split("/")
    Enum.join([Config.namespace_name() | Enum.map(parts, &Macro.camelize/1)], ".")
  end

  @doc """
  `source` with every whole occurrence of module name `old` (alone, before
  `.`, or root-qualified as `Elixir.<old>`) replaced by `new`.
  """
  @spec rename(String.t(), String.t(), String.t()) :: String.t()
  def rename(source, old, new) do
    pattern = Regex.compile!("(?<![\\w.])(Elixir\\.)?#{Regex.escape(old)}(?!\\w)")
    Regex.replace(pattern, source, fn _, root -> root <> new end)
  end

  defp new_module(nil, to), do: new_module(module_for(to), to)

  defp new_module(name, _to) when is_binary(name) do
    name = String.replace_prefix(name, "Elixir.", "")
    ns = Config.namespace_name()
    ns_parts = String.split(ns, ".")
    part = Regex.compile!("^[A-Z][A-Za-z0-9_]*$")

    case Enum.split(String.split(name, "."), length(ns_parts)) do
      {^ns_parts, [first | _] = rest} ->
        cond do
          not Enum.all?(ns_parts ++ rest, &(&1 =~ part)) ->
            {:error, "#{name} isn't a module name (parts like `DateSlider`, joined by `.`)"}

          first =~ Regex.compile!("^G\\d+$") ->
            {:error, "#{ns}.G<n> names are the generations' own; pick another module name"}

          true ->
            {:ok, name}
        end

      _ ->
        {:error, "the module must be named #{ns}.*, got #{name}"}
    end
  end

  defp new_module(_other, _to), do: {:error, "`module` must be a string"}

  defp read(from, keeper) do
    case Dyn.stage_read(from, keeper) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> DynTool.error(reason, from)
    end
  end

  defp top_module(source, from) do
    first_code_line =
      source
      |> String.split("\n")
      |> Enum.find(fn line ->
        trimmed = String.trim_leading(line)
        trimmed != "" and not String.starts_with?(trimmed, "#")
      end)

    defmodule_line =
      Regex.compile!(
        "^[ \\t]*defmodule[ \\t]+((?:[A-Z][A-Za-z0-9_]*)(?:\\.[A-Z][A-Za-z0-9_]*)*)[ \\t]+do\\b"
      )

    case first_code_line &&
           Regex.run(defmodule_line, first_code_line, capture: :all_but_first) do
      [module] -> {:ok, module}
      _ -> {:error, "#{from} defines no module to rename"}
    end
  end

  defp put_new(to, copy, keeper) do
    case Dyn.stage_create(to, copy, keeper) do
      :ok ->
        :ok

      {:error, :exists} ->
        {:error, "#{to} already exists in staging: pick another `to`, or dyn_edit that file"}

      {:error, reason} ->
        DynTool.error(reason, to)
    end
  end

  defp header(from, to, new, copy) do
    lines = copy |> String.split("\n") |> length()

    "Copied #{from} to #{to} as #{new} (#{lines} lines). Next: dyn_edit it to fit, " <>
      "then dyn_propose."
  end

  defp listing(to, ctx) do
    case DynRead.run(%{"path" => to, "limit" => @shown}, ctx) do
      {:ok, text} ->
        if text =~ Regex.compile!("\\n\\(lines 1-\\d+ of \\d+\\)$"),
          do: text <> "; dyn_read offset #{@shown + 1} for the rest",
          else: text

      {:error, text} ->
        text
    end
  end

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      ns = Config.namespace_name()
      source = "defmodule #{ns}.A do\n  def b, do: #{ns}.A.B\nend\n"
      :ok = Dyn.stage_put("a.ex", source, ctx.dyn)
      copy = fn args -> run(args, ctx) end

      with :ok <-
             DynTool.expect(
               copy.(%{"from" => "a.ex", "to" => "c/d_e.ex"}),
               &match?({:ok, "Copied a.ex to c/d_e.ex as " <> _}, &1)
             ),
           :ok <-
             DynTool.expect(
               Dyn.stage_read("c/d_e.ex", ctx.dyn),
               &(&1 == {:ok, "defmodule #{ns}.C.DE do\n  def b, do: #{ns}.C.DE.B\nend\n"})
             ),
           :ok <-
             DynTool.expect(
               copy.(%{"from" => "a.ex", "to" => "c/d_e.ex"}),
               &match?({:error, "c/d_e.ex already exists" <> _}, &1)
             ) do
        DynTool.expect(
          copy.(%{"from" => "zz.ex", "to" => "y.ex"}),
          &match?({:error, "zz.ex is not in staging" <> _}, &1)
        )
      end
    end)
  end
end
