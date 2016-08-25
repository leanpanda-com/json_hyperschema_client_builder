defmodule JSONHyperschema.ClientBuilder do
  defmodule MissingDefinitionsError do
    defexception message: "the schema does not contain any definitions"
  end

  defmodule MissingLinksError do
    defexception message: "the definition does not have any links"
  end

  @draft4_hyperschema "http://json-schema.org/draft-04/hyper-schema"
  @draft4_schema "http://json-schema.org/draft-04/schema"
  @interagent_hyperschema "http://interagent.github.io/interagent-hyper-schema"

  defmacro defapi(api_module_name, json) do
    quote location: :keep, bind_quoted: binding() do
      unresolved = load_schema(json)
      ensure_definitions_and_links!(unresolved)
      schema = ExJsonSchema.Schema.resolve(unresolved)
      endpoint_url = JSONHyperschema.Schema.endpoint!(unresolved)
      api_module = :"Elixir.#{api_module_name}"

      defmodule api_module do
        def endpoint do
          unquote(endpoint_url)
        end

        def env do
          Application.get_env(:json_hyperschema_client_builder, __MODULE__, %{})
        end

        def http_client do
          env[:http_client] || HTTPotion
        end

        def access_token do
          env[:access_token]
        end

        def headers do
          [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Bearer #{access_token}"
          ]
        end

        definitions_ref = [:root, "definitions"]
        definitions = ExJsonSchema.Schema.get_ref_schema(schema, definitions_ref)
        Enum.each(
          definitions,
          fn ({resource_name, _definition}) ->
            defresource api_module, resource_name, schema
          end
        )
      end
    end
  end

  defmacro defresource(api_module, name, schema) do
    quote location: :keep, bind_quoted: binding() do
      resource_ref = [:root, "definitions", name]
      resource = ExJsonSchema.Schema.get_ref_schema(schema, resource_ref)
      defmodule :"#{__MODULE__}.#{to_module_name(name)}" do
        resource["links"]
        |> Stream.with_index
        |> Enum.each(
          fn ({action, i}) ->
            %{"href" => href, "rel" => rel} = action
            # the default for mathod is "GET"
            # v. http://json-schema.org/latest/json-schema-hypermedia.\
            # html#anchor36
            method = Map.get(action, "method", "GET")
            {uri_path, params} = JSONPointer.parse(href, schema)
            http_method = to_method(method)
            body_schema = if Map.has_key?(action, "schema") do
              action_schema_ref = resource_ref ++ ["links", i, "schema"]
              fragment = JSONHyperschema.Schema.denormalize_ref(
                action_schema_ref, schema
              )
              JSON.encode!(fragment)
            end
            defaction(
              api_module,
              http_method, to_action_name(rel), uri_path, params,
              body_schema
            )
          end
        )
      end
    end
  end

  # Doc:
  # * if the action has a schema, i.e. a JSON request body, the data
  #   passed when the action is called is checked against said schema.
  defmacro defaction(api_module, method, name, path, params, body_schema) do
    quote location: :keep, bind_quoted: binding() do
      {param_vars, values} = handle_action_params(params)
      if has_body?(method) do
        def unquote(:"#{name}")(unquote_splicing(param_vars), body) do
          {:ok, unresolved} = JSON.decode(unquote(body_schema))
          schema = ExJsonSchema.Schema.resolve(unresolved)
          report = ExJsonSchema.Validator.validate(schema, body)
          case report do
            {:error, _} ->
              report
            _ ->
              path = evaluate_path(unquote(path), unquote(values))
              body_json = JSON.encode!(body)
              request(unquote(api_module), unquote(method), path, body: body_json)
          end
        end
      else
        def unquote(:"#{name}")(unquote_splicing(param_vars)) do
          path = evaluate_path(unquote(path), unquote(values))
          request(unquote(api_module), unquote(method), path)
        end
      end
    end
  end

  def load_schema(json) do
    {:ok, schema} = make_schema_draft4_compatible(json)
    |> JSON.decode
    schema
  end

  def ensure_definitions_and_links!(schema) do
    unless has_definitions?(schema), do: raise MissingDefinitionsError
    Enum.each(
      schema["definitions"],
      fn ({name, definition}) ->
        if !has_links?(definition) do
          raise MissingLinksError, message: "#{name} definition does not have any links"
        end
      end
    )
  end

  def has_definitions?(schema), do: get_in(schema, ["definitions"])
  def has_links?(definition), do: get_in(definition, ["links"])

  def make_schema_draft4_compatible(json) do
    # Mega-hack
    json
    # we're using ExJsonSchema to resolve $refs
    # but it only accepts Draft 4 schemas, not hyperschemas
    |> String.replace(@draft4_hyperschema, @draft4_schema)
    |> String.replace(@interagent_hyperschema, @draft4_schema)
  end

  def has_body?(:get), do: false
  def has_body?(:delete), do: false
  def has_body?(_), do: true

  def handle_action_params(params) do
    # Build the function's parameter list
    param_vars = Enum.map(params, fn(a) -> Macro.var(a, nil) end)
    # Build a binding, so eval_string gets all the parameters
    # Example: [id: {:id, [], nil}]
    values = Enum.map(
      param_vars,
      fn({name, meta, scope}) -> {name, {name, meta, scope}} end
    )
    {param_vars, values}
  end

  # Turns ("/foo/#{bar}", [id: 123]) into "/foo/123"
  # Effectivey reversing what was done by JSONPointer.parse
  def evaluate_path(path, values) do
    path_as_code = "\"" <> path <> "\""
    {interpolated_path, _values} = Code.eval_string(path_as_code, values)
    interpolated_path
  end

  def request(api_module, method, path, params \\ []) do
    all_params = Keyword.merge([headers: api_module.headers], params)
    url = api_module.endpoint <> path
    api_module.http_client.request(method, url, all_params) |> handle_response
  end

  def to_action_name("self"), do: "get"
  def to_action_name("instances"), do: "index"
  def to_action_name(phrase) do
    phrase
    |> String.split(" ")
    |> Enum.map(&String.downcase(&1))
    |> Enum.join("_")
  end

  def to_module_name(snake_case) do
    snake_case
    |> String.split("_")
    |> Enum.map(&String.capitalize(&1))
    |> Enum.join("")
  end

  def to_method(method) do
    String.to_atom(String.downcase(method))
  end

  defp handle_response(%HTTPotion.Response{status_code: 200, body: body}) do
    {:ok, JSON.decode!(body)["data"]}
  end
  defp handle_response(%HTTPotion.Response{status_code: 201, body: body}) do
    {:ok, JSON.decode!(body)["data"]}
  end
  defp handle_response(%HTTPotion.Response{status_code: _status_code, body: body}) do
    {:error, JSON.decode!(body)["data"]}
  end
  defp handle_response(%HTTPotion.ErrorResponse{message: message}) do
    {:error, message}
  end
end
