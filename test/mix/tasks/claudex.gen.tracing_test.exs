defmodule Mix.Tasks.Claudex.Gen.TracingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Claudex.Gen.Tracing

  @moduletag :tmp_dir

  describe "run/1" do
    test "writes a runtime config where there was none", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ["langfuse"])

      source = read(tmp_dir)

      assert source =~ "import Config"
      assert source =~ "config :opentelemetry_exporter"
      assert source =~ "config :claudex, trace_content: false"
    end

    test "what it writes for langfuse loads, and builds the auth header", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ["langfuse"])

      config =
        with_env(
          %{"LANGFUSE_PUBLIC_KEY" => "pk-lf-x", "LANGFUSE_SECRET_KEY" => "sk-lf-y"},
          fn -> load(tmp_dir) end
        )

      exporter = config[:opentelemetry_exporter]

      assert exporter[:otlp_protocol] == :http_protobuf
      assert exporter[:otlp_endpoint] == "https://cloud.langfuse.com/api/public/otel"

      assert {"authorization", "Basic " <> auth} =
               List.keyfind(exporter[:otlp_headers], "authorization", 0)

      assert Base.decode64!(auth) == "pk-lf-x:sk-lf-y"

      # Langfuse rejects ingestion without this alongside the auth header.
      assert {"x-langfuse-ingestion-version", "4"} =
               List.keyfind(exporter[:otlp_headers], "x-langfuse-ingestion-version", 0)

      assert config[:claudex][:trace_content] == false
    end

    test "LANGFUSE_HOST redirects it at a self-hosted install", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, ["langfuse"])

      config =
        with_env(
          %{
            "LANGFUSE_PUBLIC_KEY" => "pk-lf-x",
            "LANGFUSE_SECRET_KEY" => "sk-lf-y",
            "LANGFUSE_HOST" => "http://localhost:3000"
          },
          fn -> load(tmp_dir) end
        )

      assert config[:opentelemetry_exporter][:otlp_endpoint] ==
               "http://localhost:3000/api/public/otel"
    end

    test "the otlp default loads and names only the protocol", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, [])

      config = load(tmp_dir)

      # Everything else comes from OTEL_EXPORTER_OTLP_*, which the exporter
      # reads itself. Writing an endpoint here would fight that.
      assert config[:opentelemetry_exporter] == [otlp_protocol: :http_protobuf]
      refute read(tmp_dir) =~ "LANGFUSE"
    end

    test "names the service after the project, so traces are not unknown_service" do
      # File.cd! so the task reads this project's app name, which is what it
      # has to go on.
      config =
        File.cd!(System.tmp_dir!(), fn ->
          tmp =
            Path.join(
              System.tmp_dir!(),
              "claudex_gen_tracing_#{System.unique_integer([:positive])}"
            )

          File.mkdir_p!(tmp)
          generate(tmp, [])
          on_exit(fn -> File.rm_rf!(tmp) end)
          load(tmp)
        end)

      assert config[:opentelemetry][:resource] == %{service: %{name: "claudex"}}
    end

    test "appends to a runtime config that already exists", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "import Config\n\nconfig :my_app, foo: :bar\n")

      generate(tmp_dir, [])

      config = load(tmp_dir)

      assert config[:my_app][:foo] == :bar
      assert config[:opentelemetry_exporter][:otlp_protocol] == :http_protobuf
    end

    test "refuses to write a second exporter config", %{tmp_dir: tmp_dir} do
      generate(tmp_dir, [])

      assert_raise Mix.Error, ~r/already configures an exporter/, fn ->
        generate(tmp_dir, [])
      end
    end

    test "refuses a backend it has not been checked against", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/expected one of otlp, langfuse/, fn ->
        generate(tmp_dir, ["honeycomb"])
      end
    end
  end

  defp generate(tmp_dir, args) do
    File.cd!(tmp_dir, fn ->
      capture_io(fn -> Tracing.run(args) end)
    end)
  end

  defp path(tmp_dir), do: Path.join(tmp_dir, "config/runtime.exs")

  defp read(tmp_dir), do: tmp_dir |> path() |> File.read!()

  defp write(tmp_dir, source) do
    full = path(tmp_dir)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, source)
  end

  defp load(tmp_dir), do: tmp_dir |> path() |> Config.Reader.read!()

  defp with_env(variables, fun) do
    previous = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(variables)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
