defmodule Claudex.ContentBlock.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Claudex.{ContentBlock, Message}
  alias Claudex.ContentBlock.{Document, Image}

  describe "Image" do
    test "builds each of the three sources the API takes" do
      assert Image.base64("ZGF0YQ==", "image/png") |> ContentBlock.to_param() == %{
               type: "image",
               source: %{type: "base64", media_type: "image/png", data: "ZGF0YQ=="}
             }

      assert Image.url("https://example.com/a.png") |> ContentBlock.to_param() == %{
               type: "image",
               source: %{type: "url", url: "https://example.com/a.png"}
             }

      assert Image.file("file_1") |> ContentBlock.to_param() == %{
               type: "image",
               source: %{type: "file", file_id: "file_1"}
             }
    end

    test "leaves cache_control out unless it was given" do
      refute Map.has_key?(ContentBlock.to_param(Image.file("file_1")), :cache_control)

      assert %{cache_control: %{type: "ephemeral"}} =
               "file_1"
               |> Image.file(cache_control: %{type: "ephemeral"})
               |> ContentBlock.to_param()
    end
  end

  describe "Document" do
    test "builds each of the four sources the API takes" do
      assert Document.pdf("ZGF0YQ==") |> ContentBlock.to_param() == %{
               type: "document",
               source: %{type: "base64", media_type: "application/pdf", data: "ZGF0YQ=="}
             }

      assert Document.text("hello") |> ContentBlock.to_param() == %{
               type: "document",
               source: %{type: "text", media_type: "text/plain", data: "hello"}
             }

      assert %{source: %{type: "url", url: "https://example.com/a.pdf"}} =
               Document.url("https://example.com/a.pdf") |> ContentBlock.to_param()

      assert %{source: %{type: "file", file_id: "file_1"}} =
               Document.file("file_1") |> ContentBlock.to_param()
    end

    test "carries the fields that tell Claude what the document is" do
      param =
        "file_1"
        |> Document.file(title: "Q3 report", context: "internal only", citations: true)
        |> ContentBlock.to_param()

      assert param.title == "Q3 report"
      assert param.context == "internal only"
      assert param.citations == %{enabled: true}
    end

    test "takes the citations object as it is, for anything else the API grows" do
      assert %{citations: %{enabled: true, other: 1}} =
               "file_1"
               |> Document.file(citations: %{enabled: true, other: 1})
               |> ContentBlock.to_param()
    end

    test "an absent option stays out of the request" do
      param = ContentBlock.to_param(Document.pdf("ZGF0YQ=="))

      assert Enum.sort(Map.keys(param)) == [:source, :type]
    end
  end

  test "they go into a message like any other block" do
    message = Message.user([Image.file("file_1"), %{type: "text", text: "what is this?"}])

    assert Message.to_param(message) == %{
             role: "user",
             content: [
               %{type: "image", source: %{type: "file", file_id: "file_1"}},
               %{type: "text", text: "what is this?"}
             ]
           }
  end

  test "a stored block decodes and goes back exactly as it came" do
    # Fields Claudex doesn't model, like an image's transformations, survive
    # the round trip because the block replays the map it was decoded from.
    raw = %{
      "type" => "image",
      "source" => %{"type" => "file", "file_id" => "file_1"},
      "transformations" => %{"oversized_image" => "error"}
    }

    assert %Image{source: %{"type" => "file"}} = block = ContentBlock.decode(raw)
    assert ContentBlock.to_param(block) == raw
  end
end
