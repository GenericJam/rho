defmodule Rho.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/rho"
  @version "0.1.0"

  def project do
    [
      app: :rho,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Unconsolidated in tests, as on a host that doesn't consolidate: a Dyn
      # module's `defimpl` then dispatches, which the Rho.Untrusted tests need.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description:
        "An agent core for Elixir apps: pi-agent-core's loop, omp/pi JSONL sessions, " <>
          "compaction, tools, and model sign-in (subscription OAuth or API keys) on req_llm.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # No `mod:`: a host starts `Rho.Supervisor` in its own tree (mob apps
  # start their code by hand, not through OTP's application start).
  def application do
    [extra_applications: [:logger, :crypto, :ssl, :inets]]
  end

  defp deps do
    [
      {:req_llm, "~> 1.26"},
      {:req, "~> 0.7"},
      {:finch, "~> 0.24"},
      {:jason, "~> 1.4"},
      {:llm_db, "~> 2026.9"},
      # Dyn screens are mob screens: `Rho.Dyn.Screens.Mob` compiles when the
      # host has mob (rho's own tests run it too).
      {:mob, "~> 0.9.17", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Loop & sessions": [Rho, Rho.Loop, Rho.Events, Rho.Session, Rho.Compaction, Rho.Artifacts],
        Tools: [
          Rho.Tool,
          Rho.ToolRegistry,
          Rho.ToolRegistry.Source,
          Rho.ToolRunner,
          Rho.Tools.ReadArtifact,
          Rho.Tools.Todo
        ],
        "Models & usage": [
          Rho.LLM,
          Rho.LLM.ReqLLM,
          Rho.LLMCatalog,
          Rho.Models,
          Rho.Usage,
          Rho.Usage.Fetch,
          Rho.Budget
        ],
        "Sign-in & credentials": [
          Rho.Auth,
          Rho.Auth.Login,
          Rho.Auth.OAuthFlow,
          Rho.CredentialStore,
          Rho.CredentialStore.File
        ],
        "Host seams": [Rho.Supervisor, Rho.Config, Rho.Settings, Rho.Settings.File],
        Dyn: [
          Rho.Dyn,
          Rho.Dyn.Config,
          Rho.Dyn.Keeper,
          Rho.Dyn.Approval,
          Rho.Dyn.Approval.Biometric,
          Rho.Dyn.AutoApprove,
          Rho.Dyn.Screens,
          Rho.Dyn.Screens.Mob,
          Rho.Dyn.Screens.None,
          Rho.Dyn.Seed,
          Rho.Dyn.Source,
          Rho.Dyn.Generation,
          Rho.Dyn.Check,
          Rho.Untrusted
        ],
        "Dyn internals": [
          Rho.Dyn.Registry,
          Rho.Dyn.Store,
          Rho.Dyn.Compiler,
          Rho.Dyn.Selftest,
          Rho.Dyn.Reuse,
          Rho.Dyn.Trace,
          Rho.Dyn.Diff,
          Rho.Dyn.LogGuard
        ],
        "Dyn tools": ~r/^Rho\.Tools\.Dyn/
      ]
    ]
  end
end
