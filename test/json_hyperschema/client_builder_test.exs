defmodule TestData do
  def endpoint, do: "http://api.example.com"

  def fixtures_path, do: Path.join("test", "fixtures")

  def good_schema do
    good_schema_pathname = Path.join(fixtures_path, "good_schema.json")
    File.read!(good_schema_pathname)
    |> JSX.decode!
  end

  def thing_data do
    %{
      "data" => %{
        "type" => "thing",
        "attributes" => %{"weight" => 22}
      }
    }
  end

  def bad_data, do: %{"data" => %{"ciao" => "hello"}}

  def no_endpoint_schema do
    %{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "definitions" => %{}
    }
  end

  def no_definitions_schema do
    %{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "links" => [%{"rel" => "self", "href" => endpoint}]
    }
  end

  def no_links_error do
    %{
      "$schema" => "http://json-schema.org/draft-04/hyper-schema",
      "links" => [%{"rel" => "self", "href" => endpoint}],
      "definitions" => %{
        "thing" => %{
        }
      }
    }
  end

  def thing_id, do: 123

  def response_data, do: %{"ciao" => "hello"}

  def response_content, do: %{"data" => response_data}

  def response_body, do: JSX.encode!(response_content)

  def set_fake_client(client) do
    Application.put_env(
      :json_hyperschema_client_builder,
      My.Client,
      [http_client: client]
    )
  end
end

defmodule TestClientBuilder do
  import JSONHyperschema.ClientBuilder

  def build(schema) do
    json = JSX.encode!(schema)
    defapi "My.Client", json
  end
end

defmodule FakeHTTPClient do
  def request(method, url, options) do
    send self, {__MODULE__, :request, {method, url, options}}
    %HTTPotion.Response{status_code: 200, body: TestData.response_body}
  end
end

defmodule JSONHyperschema.ClientBuilderTest do
  use ExUnit.Case, async: true
  import TestData

  setup context do
    unless context[:skip_good_schema], do: TestClientBuilder.build(good_schema)
    if context[:http], do: set_fake_client(FakeHTTPClient)

    on_exit fn ->
      unless context[:skip_good_schema] do
        :code.purge(My.Client)
        :code.purge(My.Client.Thing)
        :code.delete(My.Client)
        :code.delete(My.Client.Thing)
      end
    end

    :ok
  end

  describe "schema errors" do
    @tag :skip_good_schema
    test "it fails if the schema has no endpoint" do
      assert_raise(
        JSONHyperschema.Schema.MissingEndpointError,
        fn -> TestClientBuilder.build(no_endpoint_schema) end
      )
    end

    @tag :skip_good_schema
    test "it fails if there are no definitions" do
      assert_raise(
        JSONHyperschema.ClientBuilder.MissingDefinitionsError,
        fn -> TestClientBuilder.build(no_definitions_schema) end
      )
    end

    @tag :skip_good_schema
    test "it fails if there are no links in a definition" do
      assert_raise(
        JSONHyperschema.ClientBuilder.MissingLinksError,
        fn -> TestClientBuilder.build(no_links_error) end
      )
    end
  end

  test "it defines a module for the Client" do
    assert Code.ensure_loaded(My.Client)
  end

  test "it defines a module for the each resource" do
    assert Code.ensure_loaded(My.Client.Thing)
  end

  test "it defines functions for each link" do
    functions = My.Client.Thing.__info__(:functions)
    assert functions == [create: 1, index: 0, index: 1, update: 2]
  end

  test "it validates the supplied body against the schema" do
    {:error, messages} = My.Client.Thing.create(bad_data)

    assert messages == [
      {"Schema does not allow additional properties.", "#/data/ciao"},
      {"Required property type was not present.", "#/data"},
      {"Required property attributes was not present.", "#/data"}
    ]
  end

  @tag :http
  test "it extracts the endpoint from the schema" do
    My.Client.Thing.index

    assert_receive {FakeHTTPClient, :request, {_method, url, _parameters}}, 100

    assert String.starts_with?(url, endpoint)
  end

  @tag :http
  test "it calls the endpoint" do
    My.Client.Thing.create(thing_data)

    assert_receive {FakeHTTPClient, :request, _}, 100
  end

  @tag :http
  test "it uses the correct HTTP verb" do
    My.Client.Thing.create(thing_data)

    assert_receive {FakeHTTPClient, :request, {:post, _, _}}, 100
  end

  @tag :http
  test "it inserts URL parameters" do
    My.Client.Thing.update(thing_id, thing_data)

    assert_receive {FakeHTTPClient, :request, {_method, url, _parameters}}, 100

    assert url == "#{endpoint}/things/#{thing_id}"
  end

  @tag :http
  test "it adds query parameters" do
    My.Client.Thing.index(%{"filter[query]" => "bar"})

    assert_receive {FakeHTTPClient, :request, {:get, url, _parameters}}, 100
    assert String.ends_with?(url, "?filter%5Bquery%5D=bar")
  end

  @tag :http
  test "if the query has no required parameters, params are optional" do
    My.Client.Thing.index
  end

  @tag :http
  test "it sends the JSON body" do
    My.Client.Thing.create(thing_data)

    assert_receive {FakeHTTPClient, :request, {:post, _, parameters}}, 100
    assert parameters[:body] == JSX.encode!(thing_data)
  end

  @tag :http
  test "it returns OK if the call succeeds" do
    {:ok, _} = My.Client.Thing.create(thing_data)
  end

  @tag :http
  test "it returns the JSON-decoded response body" do
    {:ok, body} = My.Client.Thing.index(%{"filter[query]" => "bar"})

    assert body == response_data
  end
end
