defmodule Rho.BudgetTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Budget
  alias Rho.Loop
  alias Rho.Settings.File, as: Settings

  @moduletag :tmp_dir
  @moduletag :capture_log

  test "spend adds up per day, old days drop off, the cap is from settings", %{tmp_dir: dir} do
    today = ~D[2026-10-03]
    :ok = Budget.record(dir, 0.25, today)
    :ok = Budget.record(dir, 0.5, today)
    :ok = Budget.record(dir, 0.75, Date.add(today, -1))
    # no cost reported, or a refund-looking number: nothing changes
    :ok = Budget.record(dir, 0, today)
    :ok = Budget.record(dir, nil, today)

    assert Budget.spent(dir, today) == 0.75
    assert Budget.spent(dir, Date.add(today, -1)) == 0.75
    assert Budget.check(dir, today) == :ok

    :ok = Settings.put_daily_cap(0.7, dir)
    assert Budget.check(dir, today) == {:over, 0.75, 0.7}
    # a new day starts from zero
    assert Budget.check(dir, Date.add(today, 1)) == :ok

    # a day past the 31 kept falls out when the ledger is next written
    :ok = Budget.record(dir, 0.1, Date.add(today, 32))
    assert Budget.spent(dir, today) == 0.0
    assert Budget.spent(dir, Date.add(today, 32)) == 0.1
  end

  test "the loop refuses the next model call once a reply reaches the cap", %{tmp_dir: dir} do
    :ok = Settings.put_daily_cap(0.01, dir)

    %{loop: loop} =
      start_loop(
        dir,
        [
          [{:usage, %{input_tokens: 10, output_tokens: 5, total_cost: 0.012}}, {:text, "one"}],
          [{:text, "never sent"}]
        ],
        budget: dir
      )

    :ok = Loop.prompt(loop, "first")
    assert %{reason: :done} = List.last(collect())
    assert Budget.spent(dir) == 0.012

    :ok = Loop.prompt(loop, "second")
    events = collect()
    assert %{reason: :cost_cap} = List.last(events)
    refute Enum.any?(events, &match?(%{type: :message_update}, &1))

    assert [notice] =
             for(%{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events, do: e)

    assert notice["content"] =~ "Daily cost cap reached: $0.01 of $0.01"
  end

  test "without a budget the loop has no cap", %{tmp_dir: dir} do
    :ok = Settings.put_daily_cap(0.0, dir)
    %{loop: loop} = start_loop(dir, [[{:text, "fine"}]])
    :ok = Loop.prompt(loop, "go")
    assert %{reason: :done} = List.last(collect())
  end
end
