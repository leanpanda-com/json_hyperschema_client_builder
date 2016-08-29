defmodule JSONHyperschema.ClientBuilder do
  @moduledoc """
  This module provides a series of macros that transform a JSON hyperschema
  into set of client modules.
  """

  defmodule MissingDefinitionsError do
    defexception message: "the schema does not contain any definitions"
  end

  @draft4_hyperschema "http://json-schema.org/draft-04/hyper-schema"
  @draft4_schema "http://json-schema.org/draft-04/schema"
  @interagent_hyperschema "http://interagent.github.io/interagent-hyper-schema"

  @doc """
  Defines an API client based on a JSON hyperschema.

  This macro defines the top-level client module and submodules each defined
  type (via defresource).

  ## Example

      schema_json = File.read!(schema_path)
      defapi Foo.Client, schema_path

  will create a submodule under Foo.Client for each type definition in the
  schema, and a function for each API call described by "links".

  If the schema contains

      ...
      "definitions": {
        "bar": {
          "links": [
            {
              "title": "Info",
              "rel": "self",
              "description": "Information about a bar",
              "href": "/bars/{(%23%2Fdefinitions%2Fbar%2Fdefinitions%2Fidentity)}",
              "method": "GET",
              ...
            }
          ]
        }
      }
      ...

  The function `get/1` in the module `Foo.Client.Bar` will be defined.
  The function's parameter will be the value of the `identity` to be inserted
  in the URL.
  """
  defmacro defapi(api_module_name, json) do
    quote location: :keep, bind_quoted: binding() do
      unresolved = load_schema(json)
      ensure_definitions! unresolved
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

  @doc """
  Defines a module for a type (found in a JSON schema definition) and defines a
  function for each of the type's links (via defaction).
  """
  defmacro defresource(api_module, name, schema) do
    quote location: :keep, bind_quoted: binding() do
      resource_ref = [:root, "definitions", name]
      resource = ExJsonSchema.Schema.get_ref_schema(schema, resource_ref)
      links = resource["links"] || []
      defmodule :"#{__MODULE__}.#{to_module_name(name)}" do
        links
        |> Stream.with_index
        |> Enum.each(
          fn ({action, i}) ->
            # the default value for method is "GET"
            # v. http://json-schema.org/latest/json-schema-hypermedia.\
            # html#anchor36
            method = Map.get(action, "method", "GET")
            href = action["href"]
            {uri_path, params} = JSONPointer.parse(href, schema)
            http_method = to_method(method)
            action_name = unique_action_name(action, links)
            body_schema = if Map.has_key?(action, "schema") do
              # Get a micro schema for the call parameters
              action_schema_ref = resource_ref ++ ["links", i, "schema"]
              JSONHyperschema.Schema.denormalize_ref(
                action_schema_ref, schema
              )
            end
            defaction(
              api_module,
              http_method, action_name, uri_path, params,
              body_schema
            )
          end
        )
      end
    end
  end

  @doc """
  Builds a function based on the needs of the schema.

  * JSON pointers inside hrefs become function parameters.
    For example:
      `"href": "/things/{(%23%2Fdefinitions%2Fthing%2Fdefinitions%2Fidentity)}"`
    contains the JSON pointer
      `#/definitions/thing/definitions/identity`
    which is resolved to the 'thing' attribute 'id', so the function becomes:
      `Foo.Bar.get(id, ...)`

  * if the action has a schema, the last function parameter is `params`. And
    when the function is called the params are checked against the action's
    schema.

  * if its the type of method that has a body, the params are JSON encoded and
    sent as the body, otherwise they are added as URL query parameters.
  """
  defmacro defaction(api_module, method, name, path, params, body_schema) do
    quote location: :keep, bind_quoted: binding() do
      # 1. Set up the function's parameter list

      {method_params, values} = handle_action_params(params)
      # If we have a schema, we need to accept params
      params_var = if body_schema do
        Macro.var(:params, nil)
      end

      # Add `params` as the last function parameter
      method_params = if params_var do
        # If there are "required" parameters, then `params` is required
        if Map.has_key?(body_schema, "required") && length(body_schema["required"]) > 0 do
          method_params ++ [params_var]
        else
          # Otherwise, make it an optional parameter with an empty Map as default.
          method_params ++ [quote do: unquote(Macro.var(:params, nil)) \\ %{}]
        end
      else
        method_params
      end

      # 2. Build the function's code

      # The URL is created by inserting parameter values into the URL template.
      path_assignment = if params_var && !has_body?(method) do
        # Add encoded params to the URL as query parameters
        quote do
          path = evaluate_path(unquote(path), unquote(values)) <>
            "?#{URI.encode_query(unquote(params_var))}"
        end
      else
        quote do
          path = evaluate_path(unquote(path), unquote(values))
        end
      end

      request_call = if params_var && has_body?(method) do
        # Pass the JSON-encoded params as the request body
        quote do
          body_json = JSX.encode!(unquote(params_var))
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
        # Just make the request
        quote do
          unquote(request_call)
        end
      end

      method_name = method |> to_string |> String.upcase
      action_docs = """
      Calls `#{method_name} #{path}`
      """

      action_docs = if body_schema do
        if has_body?(method) do
          action_docs <> """

          `params` is JSON encoded and passed as the request body.
          """
        else
          action_docs <> """

          `params` is added to the URL as query parameters.
          """
        end
      else
        action_docs
      end

      action_docs = if body_schema do
        action_docs <> """

        ## params Schema

        ```json
        #{JSX.encode!(body_schema, space: 1, indent: 2)}
        ```
        """
      else
        action_docs
      end

      # 3. Finally, we can define the actual function:

      Module.put_attribute(__MODULE__, :doc, {1, action_docs}, [])

      def unquote(:"#{name}")(unquote_splicing(method_params)) do
        unquote(path_assignment)
        unquote(validation_and_call)
      end
    end
  end

  @doc false
  def load_schema(json) do
    {:ok, schema} = make_schema_draft4_compatible(json)
    |> JSX.decode
    schema
  end

  @doc false
  defp make_schema_draft4_compatible(json) do
    # Mega-hack
    json
    # we're using ExJsonSchema to resolve $refs
    # but it only accepts Draft 4 schemas, not hyperschemas
    |> String.replace(@draft4_hyperschema, @draft4_schema)
    |> String.replace(@interagent_hyperschema, @draft4_schema)
  end

  @doc false
  def ensure_definitions!(schema) do
    unless has_definitions?(schema), do: raise MissingDefinitionsError
  end

  defp has_definitions?(schema), do: get_in(schema, ["definitions"])

  @doc false
  def has_body?(:get), do: false
  def has_body?(:delete), do: false
  def has_body?(_), do: true

  @doc false
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

  @doc false
  # Turns ("/foo/#{bar}", [id: 123]) into "/foo/123"
  # Effectivey reversing what was done by JSONPointer.parse
  def evaluate_path(path, values) do
    path_as_code = "\"" <> path <> "\""
    {interpolated_path, _values} = Code.eval_string(path_as_code, values)
    interpolated_path
  end

  @doc false
  def unique_action_name(action, actions) do
    others = Enum.filter(actions, fn (a) -> !Map.equal?(a, action) end)
    this_basic = basic_action_name(action)
    other_basic = Enum.map(others, fn (a) -> basic_action_name(a) end)
    found = Enum.find(other_basic, fn (r) -> r == this_basic end)
    case found do
      nil -> this_basic
      _   ->
        index = Enum.find_index(actions, fn (a) -> Map.equal?(a, action) end)
        this_basic <> "_" <> to_string(index + 1)
    end
  end

  @doc false
  def basic_action_name(%{"rel" => "self", "method" => "GET"}), do: "get"
  def basic_action_name(%{"rel" => "self", "method" => "POST"}), do: "post"
  def basic_action_name(%{"rel" => "instances", "method" => "GET"}), do: "index"
  def basic_action_name(%{"rel" => rel}) do
    rel
    |> String.split(" ")
    |> Enum.map(&String.downcase(&1))
    |> Enum.join("_")
  end

  @doc false
  def to_module_name(snake_case) do
    snake_case
    |> String.split("_")
    |> Enum.map(&String.capitalize(&1))
    |> Enum.join("")
  end

  @doc false
  def to_method(method) do
    method |> String.downcase |> String.to_atom
  end

  @doc false
  def validate_parameters(params, schema) do
    resolved = ExJsonSchema.Schema.resolve(schema)
    ExJsonSchema.Validator.validate(resolved, params)
  end

  @doc false
  def request(api_module, method, path, params \\ []) do
    all_params = Keyword.merge([headers: api_module.headers], params)
    url = api_module.endpoint <> path
    api_module.http_client.request(method, url, all_params) |> handle_response
  end

  defp handle_response(%HTTPotion.Response{status_code: 200, body: body}) do
    {:ok, JSX.decode!(body)}
  end
  defp handle_response(%HTTPotion.Response{status_code: 201, body: body}) do
    {:ok, JSX.decode!(body)}
  end
  defp handle_response(%HTTPotion.Response{status_code: _status_code, body: body}) do
    {:error, JSX.decode!(body)}
  end
  defp handle_response(%HTTPotion.ErrorResponse{message: message}) do
    {:error, message}
  end
end
