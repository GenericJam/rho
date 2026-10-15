defmodule Rho.Tools.DynPropose do
  @moduledoc """
  Core tool: turn the Dyn staging copy into a candidate generation
  (`Rho.Dyn.propose/2`: static check, compile, selftests). It
  never activates anything itself: the human approves on the phone, or has
  turned approve all on (`Rho.Dyn.AutoApprove`), when the host's UI
  activates it as it arrives. Description and result say which.
  """
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Dyn.AutoApprove
  alias Rho.Dyn.Check
  alias Rho.Dyn.Config
  alias Rho.Tools.DynTool

  @diff_max 12_000

  @impl true
  def name, do: "dyn_propose"

  @impl true
  def description do
    "Propose the staged Dyn sources as a new generation: they are checked, compiled and " <>
      "selftested, and the result (diff, tests, or every error with file:line) comes back. " <>
      activation_note()
  end

  defp activation_note do
    if AutoApprove.on?(),
      do:
        "The human has turned approve all on, so a passing proposal is activated " <>
          "automatically, on probation; don't ask them to approve it.",
      else:
        "It does NOT activate anything: the human must approve it on the phone with the " <>
          "screen lock (fingerprint, face, PIN, pattern, password or passcode)."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "rationale" => %{
          "type" => "string",
          "description" => "One line: what the change does and why (shown to the human)."
        }
      },
      "required" => ["rationale"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 120_000

  @impl true
  def run(args, ctx) do
    keeper = DynTool.keeper(ctx)
    auto? = AutoApprove.on?()

    case Dyn.propose(args["rationale"] || "", keeper) do
      {:ok, proposal} ->
        live = if auto?, do: await_live(proposal.n, keeper, ctx), else: :ask
        {:ok, proposed(proposal, live)}

      {:error, reason} ->
        {:error, refused(reason, keeper)}
    end
  end

  # Approve all: the host's UI activates the candidate as it arrives, and
  # its front then restarts on it. Answer once both happened, so the next
  # look at the front shows the new code (`ctx[:activation_wait_ms]`, 15 s;
  # the host's `Rho.Dyn.Screens.live/1` says when the front shows it).
  defp await_live(n, keeper, ctx) do
    deadline = System.monotonic_time(:millisecond) + Map.get(ctx, :activation_wait_ms, 15_000)
    poll_live(n, keeper, Config.screens(), deadline)
  end

  defp poll_live(n, keeper, screens, deadline) do
    case {live?(n, keeper, screens), System.monotonic_time(:millisecond) >= deadline} do
      {:waiting, true} ->
        if Dyn.status(keeper).generation == n, do: :active, else: :pending

      {:waiting, false} ->
        Process.sleep(100)
        poll_live(n, keeper, screens, deadline)

      {done, _late} ->
        done
    end
  end

  defp live?(n, keeper, screens) do
    cond do
      Dyn.status(keeper).generation != n -> :waiting
      function_exported?(screens, :live, 1) -> screens.live(n)
      # No front to wait for: the activation is it.
      true -> :active
    end
  catch
    # No front running (tests, a launch without one): the activation is it.
    :exit, _ -> :active
  end

  defp proposed(p, live) do
    tests =
      Enum.map_join(
        p.selftests,
        "\n",
        &"- #{&1.module} (#{&1.kind}): ok, #{&1.ms} ms: #{&1.detail}"
      )

    warnings =
      if p.warnings == [], do: "", else: "\nCompiler warnings:\n" <> Enum.join(p.warnings, "\n")

    """
    Proposed generation G#{p.n} (on top of G#{p.parent}): #{p.rationale}

    #{approval_text(p.n, live)}

    Compiled in #{p.compile_ms} ms. Selftests:
    #{tests}#{warnings}

    Diff:
    ```diff
    #{cut(p.diff)}```
    """
  end

  @probation "It runs on probation and is reverted automatically if it keeps crashing."

  defp approval_text(n, :live),
    do:
      "Activated: G#{n} is live (the human has approve all on) and the front restarted on " <>
        "it, so it shows the new code. #{@probation}"

  defp approval_text(n, :active),
    do: "Activated: G#{n} is live (the human has approve all on). #{@probation}"

  defp approval_text(n, :pending),
    do:
      "The human has approve all on, so the phone activates it automatically, without asking, " <>
        "but G#{n} isn't active yet: check dyn_status before looking at the front (if " <>
        "activating failed, the human sees the approval bar with the reason)."

  defp approval_text(_n, :ask),
    do:
      "It is NOT active. The human has to approve it on the phone with the screen lock; " <>
        "you can't activate it yourself. Once approved it runs on probation and is " <>
        "reverted automatically if it keeps crashing."

  defp cut(diff) when byte_size(diff) <= @diff_max, do: diff

  defp cut(diff) do
    String.slice(diff, 0, @diff_max) <>
      "\n… (diff cut, #{byte_size(diff) - @diff_max} more bytes)\n"
  end

  defp refused(:no_changes, keeper),
    do:
      "Nothing to propose: staging is the same as generation G#{Dyn.status(keeper).generation}. " <>
        "Change it with dyn_write or dyn_edit first."

  defp refused(:rationale_required, _keeper), do: "`rationale` is required: one line on why."

  defp refused(:proposal_limit, _keeper),
    do:
      "Too many proposals in this app launch (each one uses memory only a restart frees). " <>
        "Ask the human to restart the app, then propose again."

  defp refused(:rebuilding, _keeper),
    do:
      "The app's Core was updated, so the current generation is being rebuilt for it " <>
        "on the phone (about half a minute). Propose again once that's done."

  defp refused(:not_running, _keeper), do: "The Dyn layer isn't running."

  defp refused(%{stage: :check, violations: violations}, _keeper),
    do: "Rejected by the static check; fix these and propose again:\n" <> Check.format(violations)

  defp refused(%{stage: :compile, n: n, reason: reason}, _keeper),
    do: "Rejected: generation G#{n} doesn't compile:\n" <> reason

  defp refused(%{stage: :selftest, n: n, reason: reason}, _keeper),
    do: "Rejected: generation G#{n} failed its selftests:\n" <> reason

  defp refused(%{stage: stage, reason: reason}, _keeper), do: "Rejected (#{stage}): #{reason}"

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      ns = Config.namespace_name()
      evil = "defmodule #{ns}.Evil do\n  def x, do: System.halt()\nend\n"

      with :ok <-
             DynTool.expect(
               run(%{"rationale" => "x"}, ctx),
               &match?({:error, "Nothing to propose" <> _}, &1)
             ),
           :ok <- Dyn.stage_put("evil.ex", evil, ctx.dyn),
           :ok <-
             DynTool.expect(
               run(%{"rationale" => " "}, ctx),
               &match?({:error, "`rationale` is required" <> _}, &1)
             ) do
        DynTool.expect(
          run(%{"rationale" => "halt"}, ctx),
          &match?({:error, "Rejected by the static check;" <> _}, &1)
        )
      end
    end)
  end
end
