defmodule Rho.Artifacts do
  @moduledoc """
  The output budget: a tool result over #{16} KiB goes to
  the model as its head and tail with a marker in the middle; the full
  text is kept as an artifact the agent reads back with the `read_artifact`
  tool, a page of lines at a time.

  Artifacts live in `<data dir>/artifacts/<session id>/<call id>.txt` and
  are addressed by the call id (`artifact://<call id>`), so a session only
  sees its own.
  """

  @budget 16 * 1024
  @keep 6 * 1024

  @doc "The text to give the model for a tool result, spilling it to an artifact if it's over budget."
  @spec limit(String.t(), Path.t(), String.t(), String.t()) :: String.t()
  def limit(text, _dir, _session_id, _call_id) when byte_size(text) <= @budget, do: text

  def limit(text, dir, session_id, call_id) do
    id = safe_id(call_id)
    path = path(dir, session_id, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)

    head = head(text, @keep)
    tail = tail(text, @keep)
    omitted = byte_size(text) - byte_size(head) - byte_size(tail)

    sep = if String.ends_with?(head, "\n"), do: "", else: "\n"

    head <>
      sep <>
      "[… #{omitted} bytes omitted (the output has #{line_count(text)} lines). " <>
      "Full output: artifact://#{id}; read it with read_artifact " <>
      "(id: \"#{id}\", offset and limit in lines).]\n" <>
      tail
  end

  @doc "The artifact's file, or `{:error, :not_found}`."
  @spec find(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def find(dir, session_id, id) do
    path = path(dir, session_id, safe_id(id))
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  @doc "Bytes a tool result may have before it's spilled."
  @spec budget() :: pos_integer()
  def budget, do: @budget

  defp path(dir, session_id, id),
    do: Path.join([dir, "artifacts", safe_id(session_id), id <> ".txt"])

  # Ids come from the model: keep each to one safe path segment.
  defp safe_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.trim_leading(".")
  end

  # At most `n` bytes from the start, cut after a newline when there is one
  # in the second half, and never inside a UTF-8 character.
  defp head(text, n) do
    part = text |> binary_part(0, n) |> valid_prefix(3)

    case text_newlines(part) |> List.last() do
      {pos, 1} when pos >= div(n, 2) -> binary_part(part, 0, pos + 1)
      _ -> part
    end
  end

  defp tail(text, n) do
    part = text |> binary_part(byte_size(text) - n, n) |> valid_suffix(3)

    case text_newlines(part) do
      [{pos, 1} | _] when pos < div(n, 2) -> binary_part(part, pos + 1, byte_size(part) - pos - 1)
      _ -> part
    end
  end

  defp text_newlines(bin), do: :binary.matches(bin, "\n")

  # A cut can split one UTF-8 character (up to 3 of its bytes); text that
  # isn't UTF-8 at all is kept as it is.
  defp valid_prefix(bin, tries) do
    if tries == 0 or String.valid?(bin),
      do: bin,
      else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1), tries - 1)
  end

  defp valid_suffix(bin, tries) do
    if tries == 0 or String.valid?(bin),
      do: bin,
      else: valid_suffix(binary_part(bin, 1, byte_size(bin) - 1), tries - 1)
  end

  defp line_count(text), do: length(text_newlines(text)) + 1
end
