# Keep tests out of the real data dir: anything that resolves
# Rho.Config.data_dir/0 (credential store, sessions, usage) writes here.
data_dir = Path.join(System.tmp_dir!(), "rho-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(data_dir)
Application.put_env(:rho, :data_dir, data_dir)

# Dyn tests run as a mob host would (mob is a test dependency), set up as
# Operator is: the agent writes `TestHost.Dyn.*`, `TestHost.*` is the app's
# own code, of which Dyn code may call `TestHost.Files` (not its caller-side
# functions) and `TestHost.Tflite`.
Application.put_env(:rho, :dyn,
  namespace: TestHost.Dyn,
  screens: Rho.Dyn.Screens.Mob,
  core: [TestHost],
  allowed: [TestHost.Files, TestHost.Tflite],
  check: [
    partial: %{
      TestHost.Files => ~w(roots workspace resolve needs_access? real_path grant_capability)a
    }
  ]
)

# Model lookups (Rho.Models) go through rho's trimmed catalog, as on a device.
Rho.LLMCatalog.install!()

ExUnit.start()
