defmodule Rho.Dyn.CompilerTest do
  # Loads modules into the VM-wide code server.
  use ExUnit.Case, async: false

  alias Rho.Dyn.Check
  alias Rho.Dyn.Compiler

  defp load(source) do
    [{module, _beam}] = Code.compile_string(source)
    module
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp probe(module, version) do
    unload(module)
    load("defmodule #{inspect(module)} do\n  def version, do: #{version}\nend\n")
  end

  test "the Core digest follows the Core code the VM runs, not Dyn generations' code" do
    on_exit(fn -> Enum.each([TestHost.DigestProbe, TestHost.Dyn.G999.DigestProbe], &unload/1) end)
    before = Compiler.core_digest()

    probe(TestHost.DigestProbe, 1)
    v1 = Compiler.core_digest()
    assert v1 != before

    # Another version loaded over it, as mob_deliver loads a delivered
    # module over the build's.
    probe(TestHost.DigestProbe, 2)
    assert Compiler.core_digest() not in [before, v1]

    probe(TestHost.DigestProbe, 1)
    assert Compiler.core_digest() == v1

    probe(TestHost.Dyn.G999.DigestProbe, 1)
    assert Compiler.core_digest() == v1
  end

  defp compile(source, n), do: Compiler.compile([{"b.ex", Code.string_to_quoted!(source)}], n, [])

  @tag :capture_log
  test "a module outside the generation is refused before it loads, whatever defines it" do
    on_exit(fn -> Compiler.purge(Compiler.loaded(977)) end)
    # What the static check refuses, compiled anyway (as a library macro might).
    for {body, name} <- [
          {"defimpl Inspect, for: Atom do\n    def inspect(_a, _o), do: \"pwned\"\n  end",
           "Inspect.Atom"},
          {"require Protocol\n  Protocol.derive(Inspect, Range)", "Inspect.Range"},
          {"defmodule Elixir.Outside.Made do\n  end", "Outside.Made"},
          {"defmodule Elixir.Kernel.TestHost.Dyn.G977.B do\n  end", "Kernel.TestHost.Dyn.G977.B"}
        ] do
      md5s = Map.new([Inspect.Atom, Inspect.Range], &{&1, &1.module_info(:md5)})
      source = "defmodule TestHost.Dyn.B do\n  #{body}\nend\n"

      assert {:error, {:compile, text}} = compile(source, 977)
      assert text =~ "defines #{name}: a Dyn generation may only define", text
      assert Map.new([Inspect.Atom, Inspect.Range], &{&1, &1.module_info(:md5)}) == md5s
      assert inspect(:ok) == ":ok" and inspect(1..2) == "1..2"
      refute :code.is_loaded(Outside.Made)
      assert Compiler.loaded(977) == []
    end
  end

  @tag :capture_log
  test "an implementation for a module the build doesn't have is undone; its own stay" do
    source = """
    defmodule TestHost.Dyn.B do
      defstruct [:a]

      defimpl String.Chars do
        def to_string(_b), do: "b"
      end

      defimpl String.Chars, for: TestHost.Dyn.Missing do
        def to_string(_m), do: "m"
      end
    end
    """

    on_exit(fn -> Compiler.purge(Compiler.loaded(976)) end)
    assert {:ok, build} = compile(source, 976)

    stray = Module.concat(String.Chars, TestHost.Dyn.G976.Missing)
    refute :code.is_loaded(stray)
    own_impl = Module.concat(String.Chars, TestHost.Dyn.G976.B)
    assert Enum.sort(Compiler.loaded(976)) == Enum.sort([TestHost.Dyn.G976.B, own_impl])
    assert {:error, [%{file: file}]} = Check.beam(build.modules, 976)
    assert file == inspect(stray)
  end

  @tag :capture_log
  test "modules Module.create defines untraced are undone; a replaced one comes back from its file" do
    replaced = Rho.Test.Dyn.Approval
    md5 = replaced.module_info(:md5)
    file = :code.which(replaced)
    assert is_list(file)

    source = """
    defmodule TestHost.Dyn.C do
      Module.create(Outside.ViaCreate, quote(do: def(x, do: 1)), Macro.Env.location(__ENV__))
      Module.create(#{inspect(replaced)}, quote(do: def(x, do: 2)), Macro.Env.location(__ENV__))
    end
    """

    on_exit(fn -> Compiler.purge(Compiler.loaded(974)) end)
    assert {:ok, build} = compile(source, 974)

    refute :code.is_loaded(Outside.ViaCreate)
    assert replaced.module_info(:md5) == md5
    assert :code.which(replaced) == file
    assert Compiler.loaded(974) == [TestHost.Dyn.G974.C]

    assert {:error, violations} = Check.beam(build.modules, 974)
    files = violations |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()
    assert files == ["Outside.ViaCreate", "Rho.Test.Dyn.Approval"]
  end

  test "modules other processes define during a compile are left alone" do
    on_exit(fn ->
      Compiler.purge(Compiler.loaded(975))
      unload(Concurrent.Probe)
    end)

    slow = "defmodule TestHost.Dyn.Slow do\n  Process.sleep(300)\nend\n"
    task = Task.async(fn -> compile(slow, 975) end)
    Process.sleep(50)
    load("defmodule Concurrent.Probe do\n  def x, do: 1\nend\n")

    assert {:ok, _} = Task.await(task)
    assert :code.is_loaded(Concurrent.Probe) != false
  end

  test "only a loaded implementation for a generation's module counts as one" do
    on_exit(fn -> Enum.each([Elsewhere.TestHost.Dyn.G978.X, TestHost.Dyn.G978.X], &unload/1) end)
    load("defmodule Elsewhere.TestHost.Dyn.G978.X do\nend\n")
    assert Compiler.generation_of(Elsewhere.TestHost.Dyn.G978.X) == nil
    assert Compiler.logical(Elsewhere.TestHost.Dyn.G978.X) == "Elsewhere.TestHost.Dyn.G978.X"
    assert Compiler.loaded(978) == []
  end
end
