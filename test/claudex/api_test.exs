defmodule Claudex.APITest do
  use ExUnit.Case, async: true

  alias Claudex.API

  describe "route/1" do
    test "fills a template's placeholders with the URI-encoded bindings" do
      assert {"/v1/skills/{skill_id}/versions/{version}", options} =
               API.route(
                 method: :get,
                 url:
                   {"/v1/skills/{skill_id}/versions/{version}", skill_id: "a/b", version: "{x}"}
               )

      assert options[:url] == "/v1/skills/a%2Fb/versions/%7Bx%7D"
      assert options[:method] == :get
    end

    test "takes a plain path as its own route" do
      assert {"/v1/models", [method: :get, url: "/v1/models"]} =
               API.route(method: :get, url: "/v1/models")
    end

    test "takes :route for an absolute URL and leaves it out of the options" do
      url = "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"

      assert {"/v1/messages/batches/{message_batch_id}/results", [method: :get, url: ^url]} =
               API.route(
                 method: :get,
                 url: url,
                 route: "/v1/messages/batches/{message_batch_id}/results"
               )
    end

    test "raises for a placeholder no binding fills" do
      assert_raise ArgumentError, ~r{/v1/files/\{file_id\}}, fn ->
        API.route(method: :get, url: {"/v1/files/{file_id}", fileid: "file_1"})
      end
    end
  end
end
