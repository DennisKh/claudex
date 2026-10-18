defmodule Claudex.Live.ClientTest do
  @moduledoc """
  End-to-end coverage of the headers a derived client adds, on the plain and
  the streamed request paths.
  """

  use Claudex.TestSupport.LiveCase, async: false

  alias Claudex.{Client, Error, Message, Messages}

  @params %{model: @model, messages: [Message.user("Hello")]}

  # Unknown betas, so the API names every one it received in its 400.
  test "put_beta/2 sends its betas with the client's own" do
    assert {:error, %Error{status: 400, message: message}} =
             Claudex.new(api_key: @api_key, beta: "claudex-probe-a")
             |> Client.put_beta("claudex-probe-b")
             |> Messages.count_tokens(@params)

    assert message =~ "claudex-probe-a"
    assert message =~ "claudex-probe-b"
  end

  test "put_beta/2 reaches a streamed request", %{client: client} do
    error =
      assert_raise Error, fn ->
        client
        |> Client.put_beta("claudex-probe-b")
        |> Messages.stream!(Map.put(@params, :max_tokens, 16))
        |> Enum.to_list()
      end

    assert error.message =~ "claudex-probe-b"
  end

  # A workspace this key can't act on, so the API answers about the header.
  test "put_header/3 sends the header", %{client: client} do
    assert {:error, %Error{status: 400, message: message}} =
             client
             |> Client.put_header("anthropic-workspace-id", "wrkspc_011CZkZaBF1tNoB5wlCeusgy")
             |> Messages.count_tokens(@params)

    assert message =~ "anthropic-workspace-id"
  end
end
