# Keep tests out of the real data dir: anything that resolves
# Rho.Config.data_dir/0 (credential store, sessions, usage) writes here.
data_dir = Path.join(System.tmp_dir!(), "rho-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(data_dir)
Application.put_env(:rho, :data_dir, data_dir)

# Model lookups (Rho.Models) go through rho's trimmed catalog, as on a device.
Rho.LLMCatalog.install!()

ExUnit.start()
