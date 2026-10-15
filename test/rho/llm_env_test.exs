defmodule Rho.LLMEnvTest do
  # async: false: sets ANTHROPIC_API_KEY for the whole VM.
  use ExUnit.Case, async: false

  alias Rho.LLM.ReqLLM, as: Adapter

  setup do
    old = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-FROM-ENV")

    on_exit(fn ->
      if old,
        do: System.put_env("ANTHROPIC_API_KEY", old),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)
  end

  test "a subscription sign-in ignores an API key in the environment" do
    request = %{
      model: "anthropic:claude-haiku-4-5",
      system_prompt: "",
      messages: [],
      tools: [],
      max_tokens: 99
    }

    oauth = fn :anthropic -> {:ok, %{type: :oauth, token: "at-SUB", account_id: nil}} end
    {:ok, opts} = Adapter.options(request, oauth)

    context = ReqLLM.Context.new([ReqLLM.Context.system("SYS"), ReqLLM.Context.user("hi")])
    {:ok, model} = ReqLLM.model(request.model)
    {:ok, mod} = ReqLLM.provider(model.provider)
    {:ok, finch} = mod.attach_stream(model, context, opts, nil)

    headers = for {k, v} <- finch.headers, do: {String.downcase(k), v}
    assert {"authorization", "Bearer at-SUB"} in headers
    refute List.keymember?(headers, "x-api-key", 0)
    refute inspect(finch) =~ "FROM-ENV"
    assert Enum.any?(headers, fn {k, v} -> k == "anthropic-beta" and v =~ "oauth" end)
  end
end
