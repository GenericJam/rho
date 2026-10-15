defmodule Rho.Dyn.Reuse do
  @moduledoc """
  Incremental compiles: a proposal recompiles only the files that changed
  (or depend on a change at compile time) and reuses the rest from its
  parent generation, renamed. On a Moto G 2021 compiling the default
  front from source takes about 33 s, and recompiling a module from its
  stored Erlang code still about 350 ms (the Erlang compiler's passes):
  24 s of a one-file change to the 68-module front. So a module is reused
  by renaming its compiled binary instead; on a Mac that takes 56 ms for
  the whole front, against 1.9 s through the Erlang compiler.

  **What a generation records** (`deps`, stored next to its binaries,
  `Rho.Dyn.Store.deps/2`), by the names the agent wrote
  (`"Dyn.Notes"`):

    * per file, the modules it defines and the modules it needs at compile
      time (`Rho.Dyn.Trace`), or `nil` when that's unknown;
    * per module, the modules its compiled code names anywhere (calls,
      literals, attributes), from its debug info; a reused module names
      what its parent named.

  **Which files are reused** (`plan/2`): an unchanged file whose needs are
  known, none of which is *dirty*. A module is dirty if its file isn't
  reused (changed, deleted, or itself dirty), or if its code names a dirty
  module, directly or through others: a compile-time call into it may
  reach the change. Repeated until nothing changes.

  **Reusing** (`recompile/4`): the parent's binary with every
  `Dyn.G<parent>.*` atom in its atom table, literals and term
  chunks (debug info, attributes, docs, ...) renamed to
  `Dyn.G<n>.*`. Code refers to atoms and literals by index, so it
  is kept byte for byte, line table included: stack traces name the
  parent generation's copy of the source, which is the same text. A
  module whose code or literals still hold the parent generation's name
  (a string built at compile time, say), or that the rename doesn't
  understand, goes the slow way: the Erlang code in its debug info,
  renamed, through the Erlang compiler. If that still holds the old name
  or doesn't compile, it's compiled from source. Generations built by
  another runtime (a Core update) are never reused from: the Keeper
  rebuilds them whole.
  """

  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Config

  # Chunks of code and tables, not terms, whatever their first byte.
  @code_chunks ~w(Atom Code StrT ImpT ExpT FunT LocT Line Type Meta Recs DbgB)c

  @type deps :: %{String.t() => map()}

  @doc "Empty deps: nothing known, nothing reused."
  @spec empty() :: deps()
  def empty, do: %{"files" => %{}, "refs" => %{}}

  @doc """
  The files of `deps` (the parent's) to reuse, given the files whose
  source is the same as the parent's (`unchanged`).
  """
  @spec plan(deps(), MapSet.t(String.t())) :: MapSet.t(String.t())
  def plan(%{"files" => files, "refs" => refs}, unchanged) do
    candidates =
      for {rel, %{"needs" => needs}} <- files,
          is_list(needs),
          MapSet.member?(unchanged, rel),
          into: MapSet.new(),
          do: rel

    # Every module the parent had; one with no recorded names might name any.
    refs = for {_rel, %{"modules" => mods}} <- files, mod <- mods, into: %{}, do: {mod, refs[mod]}
    settle(files, refs, candidates)
  end

  def plan(_deps, _unchanged), do: MapSet.new()

  defp settle(files, refs, reuse) do
    dirty =
      for {rel, %{"modules" => mods}} <- files,
          not MapSet.member?(reuse, rel),
          mod <- mods,
          into: MapSet.new(),
          do: mod

    reach = reach(refs, dirty)

    kept =
      MapSet.filter(reuse, fn rel ->
        not Enum.any?(files[rel]["needs"], &MapSet.member?(reach, &1))
      end)

    if MapSet.equal?(kept, reuse), do: reuse, else: settle(files, refs, kept)
  end

  # Dirty modules and every module whose code names one, transitively.
  # Unknown names (nil) might be any.
  defp reach(refs, dirty) do
    more =
      for {mod, names} <- refs,
          not MapSet.member?(dirty, mod),
          names_any?(names, dirty),
          into: MapSet.new(),
          do: mod

    if MapSet.size(more) == 0, do: dirty, else: reach(refs, MapSet.union(dirty, more))
  end

  defp names_any?(nil, dirty), do: MapSet.size(dirty) > 0
  defp names_any?(names, dirty), do: Enum.any?(names, &MapSet.member?(dirty, &1))

  @doc """
  Generation `to`'s version of `bin`, a module of generation `from`, for
  source file `file`: `{:ok, module, binary}`, or `:error` when it has to
  be compiled from source.
  """
  @spec recompile(binary(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, module(), binary()} | :error
  def recompile(bin, from, to, file) do
    r = %{
      old: Config.generation_prefix(from),
      new: Config.generation_prefix(to),
      stale: stale(from)
    }

    with :error <- rename_beam(bin, r), do: compile_forms(bin, r, file)
  end

  # The binary as it is but for the names in its atom table, literals and
  # term chunks (debug info, attributes, docs, ...). Code refers to atoms
  # and literals by index, so it doesn't change.
  defp rename_beam(bin, %{old: old} = r) do
    with {:ok, mod, chunks} <- :beam_lib.all_chunks(bin),
         {:ok, chunks} <- rename_chunks(chunks, r, []),
         {:ok, out} <- :beam_lib.build_module(chunks),
         mod = rename(mod, old, r.new),
         {:ok, {^mod, [atoms: atoms]}} <- :beam_lib.chunks(out, [:atoms]),
         false <- Enum.any?(atoms, fn {_i, a} -> String.starts_with?(Atom.to_string(a), old) end) do
      {:ok, mod, out}
    else
      _ -> :error
    end
  end

  defp rename_chunks([], _r, acc), do: {:ok, Enum.reverse(acc)}

  defp rename_chunks([{id, data} | rest], r, acc) do
    case rename_chunk(id, data, r) do
      {:ok, data} -> rename_chunks(rest, r, [{id, data} | acc])
      :error -> :error
    end
  end

  defp rename_chunk(~c"AtU8", data, r), do: rename_atoms(data, r)
  defp rename_chunk(~c"LitT", data, r), do: rename_literals(data, r)

  # Docs aren't run, and a Dyn module's aren't read (the agent reads its
  # source): a signature may keep the old name (a struct's
  # `%Dyn.G1.Card{}`).
  defp rename_chunk(~c"Docs", data, r), do: rename_term(data, r, false)

  defp rename_chunk(id, <<131, _::binary>> = data, r) when id not in @code_chunks,
    do: rename_term(data, r, true)

  # Code, string tables, line numbers: they can't be renamed here.
  defp rename_chunk(_id, data, r), do: if(stale?(data, r), do: :error, else: {:ok, data})

  # OTP 28 and later write a negative count: each atom's length is then
  # compact-encoded (beam_asm's `encode(?tag_u, N)`), not a byte.
  defp rename_atoms(<<count::signed-32, table::binary>>, r) do
    compact? = count < 0

    with {:ok, names} <- read_atoms(table, abs(count), compact?, []),
         {:ok, table} <- write_atoms(Enum.map(names, &rename_name(&1, r.old, r.new)), compact?) do
      {:ok, IO.iodata_to_binary([<<count::signed-32>> | table])}
    end
  end

  defp read_atoms(<<>>, 0, _compact?, acc), do: {:ok, Enum.reverse(acc)}

  defp read_atoms(table, count, compact?, acc) when count > 0 do
    with {:ok, size, rest} <- read_size(table, compact?),
         <<name::binary-size(^size), rest::binary>> <- rest do
      read_atoms(rest, count - 1, compact?, [name | acc])
    else
      _ -> :error
    end
  end

  defp read_atoms(_table, _count, _compact?, _acc), do: :error

  defp read_size(<<size::4, 0::4, rest::binary>>, true), do: {:ok, size, rest}

  defp read_size(<<high::3, 1::2, 0::3, low, rest::binary>>, true),
    do: {:ok, high * 256 + low, rest}

  defp read_size(<<size, rest::binary>>, false), do: {:ok, size, rest}
  defp read_size(_table, _compact?), do: :error

  defp write_atoms(names, compact?) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case write_size(byte_size(name), compact?) do
        {:ok, size} -> {:cont, {:ok, [acc, size, name]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp write_size(size, true) when size < 16, do: {:ok, <<size::4, 0::4>>}

  defp write_size(size, true) when size < 0x800,
    do: {:ok, <<div(size, 256)::3, 1::2, 0::3, rem(size, 256)>>}

  defp write_size(size, false) when size < 256, do: {:ok, <<size>>}
  defp write_size(_size, _compact?), do: :error

  # A zero size: the table isn't compressed (OTP 28 and later).
  defp rename_literals(<<0::32, table::binary>>, r) do
    with {:ok, table} <- rename_table(table, r), do: {:ok, <<0::32, table::binary>>}
  end

  defp rename_literals(<<_size::32, compressed::binary>>, r) do
    with {:ok, table} <- rename_table(:zlib.uncompress(compressed), r),
         do: {:ok, <<byte_size(table)::32, :zlib.compress(table)::binary>>}
  end

  defp rename_table(<<count::32, entries::binary>> = table, r) do
    if stale?(table, r) do
      with {:ok, entries} <- rename_entries(entries, count, r, []),
           do: {:ok, IO.iodata_to_binary([<<count::32>> | entries])}
    else
      {:ok, table}
    end
  end

  defp rename_table(_table, _r), do: :error

  defp rename_entries(<<>>, 0, _r, acc), do: {:ok, Enum.reverse(acc)}

  defp rename_entries(<<size::32, ext::binary-size(size), rest::binary>>, count, r, acc)
       when count > 0 do
    with {:ok, ext} <- rename_term(ext, r, true),
         do: rename_entries(rest, count - 1, r, [[<<byte_size(ext)::32>>, ext] | acc])
  end

  defp rename_entries(_entries, _count, _r, _acc), do: :error

  # A term in the external format (80 marks a compressed one), renamed;
  # `strict?`: unless it still holds the old name (a string built at
  # compile time, a fun of its own).
  defp rename_term(<<131, 80, _::binary>> = ext, r, strict?) do
    with {:ok, <<131, raw::binary>>} <- encode(ext, r, strict?),
         do: {:ok, <<131, 80, byte_size(raw)::32, :zlib.compress(raw)::binary>>}
  end

  defp rename_term(ext, r, strict?),
    do: if(stale?(ext, r), do: encode(ext, r, strict?), else: {:ok, ext})

  # Encoded as the compiler encodes literals.
  defp encode(ext, r, strict?) do
    bin =
      ext
      |> :erlang.binary_to_term()
      |> rename(r.old, r.new)
      |> :erlang.term_to_binary([{:minor_version, 2}, :deterministic])

    if strict? and stale?(bin, r), do: :error, else: {:ok, bin}
  end

  # The old generation's name in the external term format: as bytes (an
  # atom, a binary, a latin-1 charlist) or as a list of small integers (a
  # charlist with other characters too).
  defp stale(from) do
    "Elixir." <> name = Config.generation_prefix(from)
    :binary.compile_pattern([name, for(<<c <- name>>, into: <<>>, do: <<97, c>>)])
  end

  defp stale?(bin, r), do: :binary.match(bin, r.stale) != :nomatch

  # Recompiling the renamed Erlang code: what the binary rename can't do.
  # The compiler doesn't compress literals (OTP 28 and later), so a string
  # still holding the old name shows in the binary.
  defp compile_forms(bin, r, file) do
    with {:ok, {_mod, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(bin, [:abstract_code]),
         forms = forms |> rename(r.old, r.new) |> refile(file),
         {:ok, mod, out} <-
           :compile.forms(forms, [
             :binary,
             :debug_info,
             :return_errors,
             :no_spawn_compiler_process
           ]),
         false <- stale?(out, r) do
      {:ok, mod, out}
    else
      _ -> :error
    end
  end

  @doc """
  The modules of generation `n` (by their written names) that `bin`'s code
  names, other than itself; nil when it has no debug info (it might name
  any).
  """
  @spec refs(module(), binary(), pos_integer()) :: [String.t()] | nil
  def refs(mod, bin, n) do
    prefix = Config.generation_prefix(n)

    case :beam_lib.chunks(bin, [:debug_info]) do
      {:ok, {^mod, [debug_info: {:debug_info_v1, _backend, _data} = info]}} ->
        info
        |> atoms(prefix, MapSet.new())
        |> MapSet.delete(mod)
        |> Enum.map(&Compiler.logical/1)
        |> Enum.sort()

      _ ->
        nil
    end
  end

  defp atoms(term, prefix, acc) when is_atom(term) do
    if String.starts_with?(Atom.to_string(term), prefix), do: MapSet.put(acc, term), else: acc
  end

  # Lists may be improper and maps may be structs (the debug info holds
  # literals: an Ecto schema's `%Ecto.Schema.Metadata{}`), so not through
  # Enumerable.
  defp atoms([head | tail], prefix, acc), do: atoms(tail, prefix, atoms(head, prefix, acc))

  defp atoms(term, prefix, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> atoms(prefix, acc)

  defp atoms(term, prefix, acc) when is_map(term),
    do: term |> :maps.to_list() |> atoms(prefix, acc)

  defp atoms(_term, _prefix, acc), do: acc

  defp rename(term, old, new) when is_atom(term) do
    name = Atom.to_string(term)
    renamed = rename_name(name, old, new)
    if renamed == name, do: term, else: String.to_atom(renamed)
  end

  # Lists may be improper (a literal's).
  defp rename([head | tail], old, new), do: [rename(head, old, new) | rename(tail, old, new)]

  defp rename(term, old, new) when is_tuple(term),
    do: term |> Tuple.to_list() |> rename(old, new) |> List.to_tuple()

  # Structs too (a literal's), so not through Enumerable.
  defp rename(term, old, new) when is_map(term),
    do: term |> :maps.to_list() |> rename(old, new) |> :maps.from_list()

  # A literal `&Mod.fun/1`.
  defp rename(term, old, new) when is_function(term) do
    info = Function.info(term)

    if info[:type] == :external,
      do: Function.capture(rename(info[:module], old, new), info[:name], info[:arity]),
      else: term
  end

  defp rename(term, _old, _new), do: term

  defp rename_name(name, old, new) do
    if String.starts_with?(name, old),
      do: new <> binary_part(name, byte_size(old), byte_size(name) - byte_size(old)),
      else: name
  end

  # Stack traces name the new generation's copy of the source.
  defp refile(forms, file) do
    Enum.map(forms, fn
      {:attribute, anno, :file, {_old, line}} -> {:attribute, anno, :file, {~c"#{file}", line}}
      form -> form
    end)
  end
end
