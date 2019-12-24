defmodule JSONHyperschema.ClientBuilderTestData do
  def endpoint, do: "http://api.example.com"

  def fixtures_path, do: Path.join("test", "fixtures")

  def good_schema do
    good_schema_pathname = Path.join(fixtures_path(), "good_schema.json")
    File.read!(good_schema_pathname)
  end

  def duplicate_rels_schema do
    duplicate_rels_pathname = Path.join(
      fixtures_path(), "duplicate_rels_schema.json"
    )
    File.read!(duplicate_rels_pathname)
  end

  def load_schema(name) do
    pathname = Path.join(fixtures_path(), name)
    File.read!(pathname)
  end

  def thing_id, do: 123

  def thing_data do
    %{
      "data" => %{
        "type" => "thing",
        "attributes" => %{"weight" => 22}
      }
    }
  end

  def part_id, do: 456

  def part_data do
    %{
      "data" => %{
        "type" => "part",
        "attributes" => %{"name" => "leg"}
      }
    }
  end

  def bad_data, do: %{"data" => %{"ciao" => "hello"}}

  def no_endpoint_schema do
    Jason.encode!(%{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "definitions" => %{}
    })
  end

  def no_definitions_schema do
    Jason.encode!(%{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "links" => [%{"rel" => "self", "href" => endpoint()}]
    })
  end

  def no_links_error do
    Jason.encode!(%{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "links" => [%{"rel" => "self", "href" => endpoint()}],
      "definitions" => %{
        "thing" => %{
        }
      }
    })
  end

  def response_data, do: %{"data" => %{"ciao" => "hello"}}

  def response_content, do: response_data()

  def response_body, do: Jason.encode!(response_content())

  def missing_content, do: %{"message" => "missing"}

  def missing_body, do: Jason.encode!(missing_content())

  def set_fake_client(client) do
    Application.put_env(
      :my_client,
      :api_config,
      [http_client: client]
    )
  end
end

defmodule TestClientBuilder do
  import JSONHyperschema.ClientBuilder

  def build(schema) do
    defapi "My.Client", :my_client, schema
  end
end

defmodule FakeHTTPClient do
  import JSONHyperschema.ClientBuilderTestData

  def request(method, url, body, headers, options) do
    send self(), {__MODULE__, :request, {method, url, body, headers, options}}
    {:ok, %HTTPoison.Response{status_code: 200, body: response_body()}}
  end
end

defmodule FakeHTTP404Client do
  import JSONHyperschema.ClientBuilderTestData

  def request(method, url, body, headers, options) do
    send self(), {__MODULE__, :request, {method, url, body, headers, options}}
    {:ok, %HTTPoison.Response{status_code: 404, body: missing_body()}}
  end
end

defmodule FakeHTTPTimeoutClient do
  import JSONHyperschema.ClientBuilderTestData

  def request(method, url, body, headers, options) do
    send self(), {__MODULE__, :request, {method, url, body, headers, options}}

    {:error, %HTTPoison.Error{id: "error_id", reason: "Timeout"}}
  end
end

defmodule JSONHyperschema.ClientBuilderTest do
  use ExUnit.Case, async: true
  import JSONHyperschema.ClientBuilderTestData

  setup context do
    case context[:schema] do
      :none -> nil
      nil   -> TestClientBuilder.build(good_schema())
      _     -> TestClientBuilder.build(context[:schema])
    end
    case context[:client] do
      :none -> nil
      nil   -> set_fake_client(FakeHTTPClient)
      _     -> set_fake_client(context[:client])
    end

    on_exit fn ->
      modules =
        case context[:modules] do
          nil -> [My.Client, My.Client.Thing, My.Client.Part]
          _   -> context[:modules]
        end
      for mod <- modules do
        :code.purge(mod)
        :code.delete(mod)
      end
    end

    :ok
  end

  describe "schema errors" do
    @tag schema: :none
    test "it fails if the schema has no endpoint" do
      assert_raise(
        JSONHyperschema.Schema.MissingEndpointError,
        fn -> TestClientBuilder.build(no_endpoint_schema()) end
      )
    end

    @tag schema: :none
    test "it fails if there are no definitions" do
      assert_raise(
        JSONHyperschema.ClientBuilder.MissingDefinitionsError,
        fn -> TestClientBuilder.build(no_definitions_schema()) end
      )
    end
  end

  test "it defines a module for the Client" do
    assert Code.ensure_loaded(My.Client)
  end

  test "it defines a module for the each resource" do
    assert Code.ensure_loaded(My.Client.Thing)
  end

  @tag schema: load_schema("resource_names.json"),
  modules: [My.Client, My.Client.HyphenatedResource, My.Client.SnakeCase]
  test "it handles resources with underscores" do
    assert Code.ensure_loaded(My.Client.SnakeCase)
  end

  @tag schema: load_schema("resource_names.json"),
  modules: [My.Client, My.Client.HyphenatedResource, My.Client.SnakeCase]
  test "it handles resources with hyphens" do
    assert Code.ensure_loaded(My.Client.HyphenatedResource)
  end

  test "it defines functions for each link" do
    thing_functions = My.Client.Thing.__info__(:functions)
    assert thing_functions == [create: 1, index: 0, index: 1, update: 2]
    part_functions = My.Client.Part.__info__(:functions)
    assert part_functions == [update: 3]
  end

  @tag schema: duplicate_rels_schema()
  test "it creates unique function names" do
    thing_functions = My.Client.Thing.__info__(:functions)
    assert thing_functions == [do_something_general: 0, do_something_specific: 1]
  end

  test "it validates the supplied body against the schema" do
    {:error, messages} = My.Client.Thing.create(bad_data())

    assert messages == [
      {"Schema does not allow additional properties.", "#/data/ciao"},
      {"Required properties type, attributes were not present.", "#/data"}
    ]
  end

  test "it extracts the endpoint from the schema" do
    My.Client.Thing.index

    assert_receive {
      FakeHTTPClient, :request, {_method, url, _body, _headers, _options}
    }, 100

    assert String.starts_with?(url, endpoint())
  end

  test "it calls the endpoint" do
    My.Client.Thing.create(thing_data())

    assert_receive {FakeHTTPClient, :request, _}, 100
  end

  test "it uses the correct HTTP verb" do
    My.Client.Thing.create(thing_data())

    assert_receive {FakeHTTPClient, :request, {:post, _, _, _, _}}, 100
  end

  test "it inserts URL parameters" do
    My.Client.Thing.update(thing_id(), thing_data())

    assert_receive {
      FakeHTTPClient, :request, {_method, url, _body, _headers, _options}
    }, 100

    assert url == "#{endpoint()}/things/#{thing_id()}"
  end

  test "it handles multiple URL parameters" do
    My.Client.Part.update(thing_id(), part_id(), part_data())

    assert_receive {
      FakeHTTPClient, :request, {_method, url, _body, _headers, _options}
    }, 100

    assert url == "#{endpoint()}/things/#{thing_id()}/parts/#{part_id()}"
  end

  test "it adds query parameters" do
    My.Client.Thing.index(%{"filter[query]" => "bar"})

    assert_receive {
      FakeHTTPClient, :request, {:get, url, _body, _headers, _options}
    }, 100
    assert String.ends_with?(url, "?filter%5Bquery%5D=bar")
  end

  test "if the query has no required parameters, params are optional" do
    My.Client.Thing.index
  end

  test "it sends the JSON body" do
    My.Client.Thing.create(thing_data())

    assert_receive {
      FakeHTTPClient, :request, {:post, _url, body, _headers, _options}
    }, 100
    assert body == Jason.encode!(thing_data())
  end

  test "it returns OK if the call succeeds" do
    {:ok, _} = My.Client.Thing.create(thing_data())
  end

  @tag client: FakeHTTP404Client
  test "it handles 404" do
    {:error, message} = My.Client.Thing.index
    assert message == missing_content()
  end

  @tag client: FakeHTTPTimeoutClient
  test "it handles HTTP transport errors" do
    {:error, message} = My.Client.Thing.index
    assert message == "Timeout"
  end

  test "it returns the JSON-decoded response body" do
    {:ok, body} = My.Client.Thing.index(%{"filter[query]" => "bar"})

    assert body == response_data()
  end
end
