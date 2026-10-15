defmodule Rho.Dyn.ApprovalTest do
  # The biometric approval is one named process.
  use ExUnit.Case, async: false

  alias Rho.Dyn.Approval.Biometric

  test "a confirmation gives one token, for exactly that subject" do
    start_supervised!(Biometric)

    assert Biometric.request({:activate, 5}) == {:error, :approval_required}
    :ok = Biometric.confirm({:activate, 5})
    assert Biometric.request({:activate, 6}) == {:error, :approval_required}
    assert {:ok, token} = Biometric.request({:activate, 5})
    # the confirmation was used up
    assert Biometric.request({:activate, 5}) == {:error, :approval_required}

    assert Biometric.verify(token, {:activate, 5}) == :ok
    assert Biometric.verify(token, {:activate, 5}) == {:error, :invalid_approval}
  end

  test "a token for another subject is refused, and burned" do
    start_supervised!(Biometric)
    :ok = Biometric.confirm({:activate, 5})
    {:ok, token} = Biometric.request({:activate, 5})

    assert Biometric.verify(token, {:revert_to, 5}) == {:error, :invalid_approval}
    assert Biometric.verify(token, {:activate, 5}) == {:error, :invalid_approval}
    assert Biometric.verify({Biometric, "forged"}, {:activate, 5}) == {:error, :invalid_approval}
  end

  test "confirmations and tokens expire" do
    start_supervised!({Biometric, ttl_ms: 30})

    :ok = Biometric.confirm({:activate, 1})
    Process.sleep(50)
    assert Biometric.request({:activate, 1}) == {:error, :approval_required}

    :ok = Biometric.confirm({:activate, 1})
    {:ok, token} = Biometric.request({:activate, 1})
    Process.sleep(50)
    assert Biometric.verify(token, {:activate, 1}) == {:error, :invalid_approval}
  end

  test "without the process nothing is approved" do
    assert Biometric.request({:activate, 1}) == {:error, :approval_required}
    assert Biometric.verify(:anything, {:activate, 1}) == {:error, :approval_required}
  end
end
