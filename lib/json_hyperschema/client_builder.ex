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
              # Get a micro schema for the call parameters
              action_schema_ref = resource_ref ++ ["links", i, "schema"]
              JSONHyperschema.Schema.denormalize_ref(
                action_schema_ref, schema
              )
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
  # Builds a function based on the needs of the schema.
  #
  # * JSON pointers inside hrefs become function parameters:
  #   `"href": "/things/{(%23%2Fdefinitions%2Fthing%2Fdefinitions%2Fidentity)}"`
  # is resolved to the 'thing' attribute 'id', so the function becomes:
  #   `Foo.Bar.get(id, ...)`
  # * if the action has a schema, i.e. a JSON request body, the data
  #   passed when the action is called is checked against said schema.
  defmacro defaction(api_module, method, name, path, params, body_schema) do
    quote location: :keep, bind_quoted: binding() do
      # 1. Set up the functions parameter list

      {method_params, values} = handle_action_params(params)
      # If we have a schema, we need to accept params
      params_var = if body_schema do
        Macro.var(:params, nil)
      end

      # Add `params` as the last parameter
      method_params = if params_var do
        method_params ++ [params_var]
      else
        method_params
      end

      # 2. Build the function's code

      # The URL is created by inserting parameter values into the URL template.
      # If we have query params for a GET request, add them to the URL when we
      # create it. Otherwise, just create the URL
      path_assignment = if params_var && !has_body?(method) do
        quote do
          path = evaluate_path(unquote(path), unquote(values)) <> "?#{URI.encode_query(unquote(params_var))}"
        end
      else
        quote do
          path = evaluate_path(unquote(path), unquote(values))
        end
      end

      request_call = if params_var && has_body?(method) do
        # Pass the JSON-encoded params as the request body
        quote do
          body_json = JSON.encode!(unquote(params_var))
          request(unquote(api_module), unquote(method), path, body: body_json)
        end
      else
        quote do
          request(unquote(api_module), unquote(method), path)
        end
      end

      validation_and_call = if body_schema do
        # Do validations of the `params` parameter before making the request
        quoted_schema = Macro.escape(body_schema)
        quote do
          report = validate_parameters(unquote(params_var), unquote(quoted_schema))
          case report do
            {:error, _} ->
              report
            _ ->
              unquote(request_call)
          end
        end
      else
        quote do
          unquote(request_call)
        end
      end

      # 3. Finally, we can define the actual function:
      def unquote(:"#{name}")(unquote_splicing(method_params)) do
        unquote(path_assignment)
        unquote(validation_and_call)
      end
    end
  end

  def load_schema(json) do
    {:ok, schema} = make_schema_draft4_compatible(json)
    |> JSON.decode
    schema
  end

  def validate_parameters(params, schema) do
    resolved = ExJsonSchema.Schema.resolve(schema)
    ExJsonSchema.Validator.validate(resolved, params)
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
    method_params = Enum.map(params, fn(a) -> Macro.var(a, nil) end)
    # Build a binding, so eval_string gets all the parameters
    # Example: [id: {:id, [], nil}]
    values = Enum.map(
      method_params,
      fn({name, meta, scope}) -> {name, {name, meta, scope}} end
    )
    {method_params, values}
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
    method |> String.downcase |> String.to_atom
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
