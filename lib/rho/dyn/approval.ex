defmodule Rho.Dyn.Approval do
  @moduledoc """
  The approval gate on changing what runs (the pipeline's step 5, see
  `Rho.Dyn`):
  activating a proposed generation, or reverting to a chosen one by hand.

  The UI asks the configured implementation for a token once the human
  approved (`request/1`, reached through `Rho.Dyn.request_approval/2`);
  `Rho.Dyn.Keeper` asks the same implementation to `verify/2` it
  before it changes anything. Contract for implementations:

    * a token is for one subject: approving generation 5 doesn't activate
      generation 6, and an activation token doesn't revert;
    * a token expires (the production one after 60 s);
    * a token works once: `verify/2` consumes it. The Keeper also remembers
      every token it accepted and refuses it a second time
      (`{:error, :approval_used}`), whatever the implementation says.

  Automatic reverts (crashes on probation, boot probation) need none.
  Dropping a candidate (`Rho.Dyn.discard/2`) needs none either:
  it changes nothing that runs.

  The production implementation is `Rho.Dyn.Approval.Biometric`.
  Tests configure their own (`approval:` option of the Keeper).
  """

  @type subject ::
          {:activate, pos_integer()} | {:revert_to, non_neg_integer()} | {:auto_approve, :on}
  @type token :: term()

  @doc "A token for `subject`, if the human approved it."
  @callback request(subject()) :: {:ok, token()} | {:error, term()}

  @doc "Is `token` a valid, unexpired, unused approval of `subject`? Consumes it."
  @callback verify(token(), subject()) :: :ok | {:error, term()}
end

defmodule Rho.Dyn.Approval.Biometric do
  @moduledoc """
  The production approval: the system screen-lock prompt (fingerprint,
  face, or the phone's PIN, pattern, password or passcode) behind an
  approve control the host shows with the change (Operator's approve chip).
  This small process (`Rho.Supervisor` starts it with Dyn) holds what the
  human confirmed; only the host's UI, after the prompt passed, calls
  `confirm/1`.

  The screen's flow:

      # the approve control reported a passed prompt for subject {:activate, n}:
      :ok = Biometric.confirm({:activate, n})
      {:ok, token} = Rho.Dyn.request_approval({:activate, n})
      {:ok, gen} = Rho.Dyn.activate(n, token)

  * `confirm/1` records that the human just approved `subject`: valid for
    60 s, once.
  * `request/1` turns a fresh confirmation of exactly that subject into a
    token (consuming the confirmation); otherwise `{:error,
    :approval_required}`.
  * `verify/2` accepts a token minted for that subject, within 60 s,
    once.

  Without the process running, nothing is approved. Option: `:ttl_ms`
  (60 000).
  """
  @behaviour Rho.Dyn.Approval

  use GenServer

  alias Rho.Dyn.Approval

  @ttl_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The human approved `subject` (call right after the approve chip's `\"approved\"`)."
  @spec confirm(Approval.subject()) :: :ok
  def confirm(subject), do: GenServer.call(__MODULE__, {:confirm, subject})

  @impl Approval
  def request(subject), do: call({:request, subject})

  @impl Approval
  def verify(token, subject), do: call({:verify, token, subject})

  defp call(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :approval_required}
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> {:error, :approval_required}
  end

  # ── GenServer ──

  @impl GenServer
  def init(opts),
    do: {:ok, %{ttl: Keyword.get(opts, :ttl_ms, @ttl_ms), confirmed: %{}, tokens: %{}}}

  @impl GenServer
  def handle_call(message, from, s), do: handle(message, from, prune(s))

  defp handle({:confirm, subject}, _from, s),
    do: {:reply, :ok, %{s | confirmed: Map.put(s.confirmed, subject, expiry(s))}}

  defp handle({:request, subject}, _from, s) do
    case Map.pop(s.confirmed, subject) do
      {nil, _} ->
        {:reply, {:error, :approval_required}, s}

      {_until, confirmed} ->
        token = {__MODULE__, :crypto.strong_rand_bytes(16)}
        tokens = Map.put(s.tokens, token, {subject, expiry(s)})
        {:reply, {:ok, token}, %{s | confirmed: confirmed, tokens: tokens}}
    end
  end

  # Any attempt uses the token up.
  defp handle({:verify, token, subject}, _from, s) do
    {entry, tokens} = Map.pop(s.tokens, token)
    reply = if match?({^subject, _}, entry), do: :ok, else: {:error, :invalid_approval}
    {:reply, reply, %{s | tokens: tokens}}
  end

  # Expired confirmations and tokens are as good as absent.
  defp prune(s) do
    now = now()
    confirmed = for {_subject, until} = e <- s.confirmed, until > now, into: %{}, do: e
    tokens = for {_token, {_subject, until}} = e <- s.tokens, until > now, into: %{}, do: e
    %{s | confirmed: confirmed, tokens: tokens}
  end

  defp expiry(s), do: now() + s.ttl
  defp now, do: System.monotonic_time(:millisecond)
end
