defmodule Rho.Dyn.DiffTest do
  use ExUnit.Case, async: true

  alias Rho.Dyn.Diff

  test "changed, added and removed files, as diff -u prints them" do
    old = %{"a.ex" => "one\ntwo\nthree\n", "gone.ex" => "x\n", "same.ex" => "s\n"}
    new = %{"a.ex" => "one\n2\nthree\n", "new.ex" => "y\n", "same.ex" => "s\n"}

    assert Diff.unified(old, new) == """
           --- a/a.ex
           +++ b/a.ex
           @@ -1,3 +1,3 @@
            one
           -two
           +2
            three
           --- a/gone.ex
           +++ /dev/null
           @@ -1,1 +0,0 @@
           -x
           --- /dev/null
           +++ b/new.ex
           @@ -0,0 +1,1 @@
           +y
           """
  end

  test "changes far apart get their own hunks with three lines of context" do
    lines = Enum.map(1..20, &"l#{&1}")
    old = %{"f.ex" => Enum.join(lines, "\n") <> "\n"}

    new_lines = lines |> List.replace_at(1, "X") |> List.replace_at(18, "Y")
    new = %{"f.ex" => Enum.join(new_lines, "\n") <> "\n"}

    assert Diff.unified(old, new) == """
           --- a/f.ex
           +++ b/f.ex
           @@ -1,5 +1,5 @@
            l1
           -l2
           +X
            l3
            l4
            l5
           @@ -16,5 +16,5 @@
            l16
            l17
            l18
           -l19
           +Y
            l20
           """
  end
end
