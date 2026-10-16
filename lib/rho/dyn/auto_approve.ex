defmodule Rho.Dyn.AutoApprove do
  @moduledoc """
  The "approve all" setting: while on, the host's UI activates each
  candidate generation as it arrives instead of asking for approval (the
  same activation, so probation and revert-on-crash still apply). Only
  Dyn activations: reverting still asks.

  Kept in the credential store (`Rho.CredentialStore`, the phone's secure
  store), not a settings file, so the agent's file tools can't flip it.
  Off by default (and whenever the store can't be read). Turning it on
  takes the human's screen lock: `enable/0` needs a fresh confirmation of
  `subject/0` from the configured approval (in the app,
  `Rho.Dyn.Approval.Biometric`, fed only by the approve control's pass).
  Turning it off needs nothing. The static check rejects Dyn code that
  calls this module (`Rho.Dyn.Check`, best effort), and no tool calls
  `enable/0`.
  """

  alias Rho.CredentialStore
  alias Rho.Dyn

  @account "dyn:auto_approve"
  @subject {:auto_approve, :on}

  @doc "The approval subject that turns approve-all on."
  @spec subject() :: {:auto_approve, :on}
  def subject, do: @subject

  @doc "Is approve-all on?"
  @spec on?() :: boolean()
  def on?, do: CredentialStore.get(@account) == {:ok, "on"}

  @doc "Turns approve-all on, given the human just confirmed `subject/0`."
  @spec enable() :: :ok | {:error, term()}
  def enable do
    with {:ok, _token} <- Dyn.request_approval(@subject),
         do: CredentialStore.put(@account, "on")
  end

  @doc "Turns approve-all off."
  @spec disable() :: :ok | {:error, term()}
  def disable, do: CredentialStore.delete(@account)
end
