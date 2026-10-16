defmodule Rho.Auth.Login do
  @moduledoc """
  Signing in to a subscription (`:anthropic`, `:openai_codex`): the OAuth
  flow (`Rho.Auth.OAuthFlow`) with the provider's own localhost redirect,
  answered by this BEAM.

  `begin/1` starts a `:gen_tcp` listener on `127.0.0.1` at the redirect's
  port (54545 for Anthropic, 1455 for OpenAI: the redirects omp registers),
  opens the authorize URL in the device's browser, and when the browser is
  sent back to `http://localhost:<port>/…?code=…&state=…` exchanges the code,
  stores the credentials (`Rho.Auth.put/2`, which tells its
  subscribers) and sends whoever called `begin/1`
  `{:rho_login, provider, :ok | {:error, message}}`.

  Anthropic's authorize page may show the code (`code#state`) instead of
  redirecting; `paste/2` takes it (or the whole redirect URL) for the flow
  in progress. One flow at a time: `begin/1` replaces an unfinished one,
  and cancels an exchange still running for an older one (its result is
  never used). A redirect carrying another flow's state (an old tab) gets
  an error page and leaves the flow in progress alone; the flow ends on its
  own redirect, a paste, or after 15 minutes without either.

  The exchange runs in a worker and retries transport errors every 2 s
  for up to 9 minutes: Android blocks a backgrounded app's network (~60 s
  after it leaves the foreground), so it completes when the user switches
  back from the browser.

  Options: `:open_url` (`fn url -> :ok end`; default
  `Rho.Config.open_url/1`, which a mob app points at `Mob.Device.open_url/1`),
  `:redirect` (`fn provider -> uri end`, default the provider's), `:respond`
  (tests: `Rho.Auth.OAuthFlow`), `:flow_timeout_ms`.
  """
  use GenServer

  alias Rho.Auth
  alias Rho.Auth.OAuthFlow

  require Logger

  # Codes expire 10 minutes after issue; stop retrying a bit before that.
  @code_lifetime_ms 9 * 60_000
  @flow_timeout_ms 15 * 60_000

  @doc "Started by `Rho.Supervisor` (its `:login` option holds `opts`, see the moduledoc)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts a sign-in and opens the browser; returns the URL that was opened.
  `{:error, :not_oauth}` for a provider that takes only an API key.
  """
  @spec begin(Auth.provider()) :: {:ok, String.t()} | {:error, term()}
  def begin(provider) do
    if :oauth in Auth.kinds(provider),
      do: GenServer.call(__MODULE__, {:begin, provider, self()}),
      else: {:error, :not_oauth}
  end

  @doc """
  The host default for `config :rho, :open_url`: the computer's browser
  (`open` on macOS, `xdg-open` elsewhere on Unix, `start` on Windows),
  started without waiting for it. When there's none it logs that and
  still returns `:ok`: `begin/1` returns the URL for the host to show.
  """
  @spec open_in_browser(String.t()) :: :ok
  def open_in_browser(url) do
    {cmd, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
        _ -> {"xdg-open", [url]}
      end

    case System.find_executable(cmd) do
      nil ->
        Logger.warning("[login] no #{cmd} to open the sign-in page with")

      path ->
        {:ok, _} = Task.start(fn -> System.cmd(path, args, stderr_to_stdout: true) end)
    end

    :ok
  end

  @doc """
  Finishes the flow in progress with what the provider's page showed: a
  `code#state`, a bare code, or the redirect URL.
  """
  @spec paste(Auth.provider(), String.t()) ::
          :ok | {:error, :no_login_started | :no_code | :state_mismatch | {:started_for, atom()}}
  def paste(provider, input), do: GenServer.call(__MODULE__, {:paste, provider, input})

  @doc """
  The provider of the sign-in in progress (nil when none), whose result
  goes to the caller from now on: a page reopened during the browser flow
  takes it over from the one that started it.
  """
  @spec pending() :: Auth.provider() | nil
  def pending, do: GenServer.call(__MODULE__, {:pending, self()})

  @doc false
  # `{code, state}` from a redirect URL, a query string or `code#state`
  # (omp's parseCallbackInput); either may be nil.
  @spec parse_input(String.t()) :: {String.t() | nil, String.t() | nil}
  def parse_input(input) do
    value = String.trim(input)

    cond do
      value == "" ->
        {nil, nil}

      String.contains?(value, "code=") ->
        query =
          case URI.parse(value) do
            %URI{scheme: scheme, query: query} when scheme in ["http", "https"] -> query || ""
            _ -> String.trim_leading(value, "?")
          end

        params = URI.decode_query(query)
        {blank_nil(params["code"]), blank_nil(params["state"])}

      true ->
        case String.split(value, "#", parts: 2) do
          [code, state] -> {blank_nil(code), blank_nil(state)}
          [code] -> {code, nil}
        end
    end
  end

  # ── GenServer ──

  @impl true
  def init(opts) do
    {:ok,
     %{
       flow: nil,
       listen: nil,
       worker: nil,
       open_url: Keyword.get(opts, :open_url, &Rho.Config.open_url/1),
       redirect: Keyword.get(opts, :redirect, &OAuthFlow.default_redirect/1),
       respond: opts[:respond],
       flow_timeout_ms: Keyword.get(opts, :flow_timeout_ms, @flow_timeout_ms)
     }}
  end

  @impl true
  def handle_call({:begin, provider, notify}, _from, s) do
    s = s |> cancel_worker() |> end_flow()
    redirect = s.redirect.(provider)
    %{url: url, verifier: verifier, state: state} = OAuthFlow.start(provider, redirect)
    %URI{port: port, path: path} = URI.parse(redirect)

    case listen(port, path) do
      {:ok, sock} ->
        :ok = s.open_url.(url)
        Logger.info("[login] #{provider}: browser opened, listening on #{port}")

        flow = %{
          provider: provider,
          verifier: verifier,
          state: state,
          redirect: redirect,
          notify: notify,
          timer: Process.send_after(self(), {:flow_timeout, state}, s.flow_timeout_ms)
        }

        {:reply, {:ok, url}, %{s | flow: flow, listen: sock}}

      {:error, reason} ->
        {:reply, {:error, {:listen, port, reason}}, s}
    end
  end

  # The flow waiting for the browser, and an exchange already running, both
  # report to the new page.
  def handle_call({:pending, notify}, _from, s) do
    flow = s.flow && %{s.flow | notify: notify}
    worker = with {pid, ref, f} <- s.worker, do: {pid, ref, %{f | notify: notify}}
    {:reply, flow && flow.provider, %{s | flow: flow, worker: worker}}
  end

  def handle_call({:paste, _provider, _input}, _from, %{flow: nil} = s),
    do: {:reply, {:error, :no_login_started}, s}

  def handle_call({:paste, provider, _input}, _from, %{flow: %{provider: other}} = s)
      when other != provider,
      do: {:reply, {:error, {:started_for, other}}, s}

  def handle_call({:paste, _provider, input}, _from, %{flow: flow} = s) do
    case parse_input(input) do
      {nil, _} ->
        {:reply, {:error, :no_code}, s}

      {_code, state} when state != nil and state != flow.state ->
        {:reply, {:error, :state_mismatch}, s}

      {code, _} ->
        {:reply, :ok, start_exchange(s, code)}
    end
  end

  # The acceptor hands over the callback's query string.
  def handle_call({:callback, _query}, _from, %{flow: nil} = s), do: {:reply, :stale, s}

  def handle_call({:callback, query}, _from, %{flow: flow} = s) do
    params = URI.decode_query(query)

    cond do
      # An older sign-in's redirect (another tab, a reload): the one in progress goes on.
      params["state"] != flow.state ->
        {:reply, :stale, s}

      is_binary(params["code"]) and params["code"] != "" ->
        {:reply, :received, start_exchange(s, params["code"])}

      true ->
        why =
          Enum.join(Enum.reject([params["error"], params["error_description"]], &is_nil/1), ": ")

        {:reply, :failed, fail(s, "#{label(flow)} said no (#{why})")}
    end
  end

  @impl true
  def handle_info({:exchanged, pid, result}, %{worker: {pid, ref, flow}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(%{s | worker: nil}, flow, result)}
  end

  def handle_info({:DOWN, ref, :process, _down, reason}, %{worker: {_worker, ref, flow}} = s),
    do: {:noreply, finish(%{s | worker: nil}, flow, {:error, "crashed: #{inspect(reason)}"})}

  def handle_info({:flow_timeout, state}, %{flow: %{state: state}} = s) do
    message = "no answer from the browser in time; sign in again #{Rho.Config.hint(:sign_in)}"

    {:noreply, fail(s, message)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── exchange ──

  # The code is spent either way: the flow ends here.
  defp start_exchange(%{flow: flow} = s, code) do
    s = s |> cancel_worker() |> end_flow()
    owner = self()

    opts =
      [retry_until: System.monotonic_time(:millisecond) + @code_lifetime_ms] ++
        if(s.respond, do: [respond: s.respond], else: [])

    {pid, ref} =
      spawn_monitor(fn ->
        result = OAuthFlow.exchange(flow.provider, code, flow, flow.redirect, opts)
        send(owner, {:exchanged, self(), result})
      end)

    %{s | worker: {pid, ref, flow}}
  end

  # A newer sign-in wins: an older exchange is stopped, and a result it
  # already sent no longer matches the worker.
  defp cancel_worker(%{worker: {pid, ref, _flow}} = s) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    %{s | worker: nil}
  end

  defp cancel_worker(s), do: s

  defp end_flow(%{flow: nil} = s), do: close_listener(s)

  defp end_flow(%{flow: flow} = s) do
    Process.cancel_timer(flow.timer)
    %{close_listener(s) | flow: nil}
  end

  defp finish(s, flow, {:ok, creds}) do
    case Auth.put(flow.provider, creds) do
      :ok ->
        Logger.info("[login] #{flow.provider}: signed in")
        send(flow.notify, {:rho_login, flow.provider, :ok})

      {:error, reason} ->
        notify_error(flow, "couldn't save it: #{Auth.describe_error(reason)}")
    end

    s
  end

  defp finish(s, flow, {:error, message}) do
    notify_error(flow, message)
    s
  end

  defp fail(%{flow: flow} = s, message) do
    notify_error(flow, message)
    end_flow(s)
  end

  defp notify_error(flow, message) do
    Logger.warning("[login] #{flow.provider}: #{message}")
    send(flow.notify, {:rho_login, flow.provider, {:error, message}})
  end

  defp label(flow), do: Auth.label(flow.provider)

  # ── the localhost listener ──

  defp listen(port, path) do
    opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

    with {:ok, sock} <- :gen_tcp.listen(port, opts) do
      owner = self()
      {:ok, _} = Task.start(fn -> accept_loop(sock, path, owner) end)
      {:ok, sock}
    end
  end

  defp accept_loop(sock, path, owner) do
    case :gen_tcp.accept(sock) do
      {:ok, conn} ->
        handle_conn(conn, path, owner)
        accept_loop(sock, path, owner)

      {:error, _closed} ->
        :ok
    end
  end

  # Minimal HTTP/1.1: read the request line, answer one page, close.
  # Browsers also ask for /favicon.ico; anything but the callback path is a 404.
  defp handle_conn(conn, path, owner) do
    with {:ok, data} <- recv_head(conn, ""),
         ["GET " <> rest | _] <- String.split(data, "\r\n"),
         [target | _] <- String.split(rest, " "),
         %URI{path: ^path, query: query} <- URI.parse(target) do
      case GenServer.call(owner, {:callback, query || ""}, 10_000) do
        :received ->
          reply(
            conn,
            200,
            "<h2>Code received.</h2><p>Switch back to #{app()} to finish signing in.</p>"
          )

        :stale ->
          reply(
            conn,
            200,
            "<h2>This sign-in page is out of date.</h2>" <>
              "<p>Use the newest sign-in tab, or start the sign-in again in #{app()}.</p>"
          )

        :failed ->
          reply(conn, 200, "<h2>Sign-in failed.</h2><p>Return to #{app()}; it shows why.</p>")
      end
    else
      _ -> reply(conn, 404, "not found")
    end

    :gen_tcp.close(conn)
  end

  defp app, do: Rho.Config.app_name()

  defp recv_head(conn, acc) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: recv_head(conn, acc)

      {:error, _} = err ->
        err
    end
  end

  defp reply(conn, code, body) do
    html = "<!doctype html><meta name=viewport content='width=device-width'>" <> body

    :gen_tcp.send(conn, [
      "HTTP/1.1 #{code} #{if code == 200, do: "OK", else: "Not Found"}\r\n",
      "content-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(html)}\r\n",
      "connection: close\r\n\r\n",
      html
    ])
  end

  defp close_listener(%{listen: nil} = s), do: s

  defp close_listener(%{listen: sock} = s) do
    :gen_tcp.close(sock)
    %{s | listen: nil}
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
