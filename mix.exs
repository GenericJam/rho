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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end
