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
      defapi "Foo.Client", :my_app, schema_json

  will create a submodule under Foo.Client for each type definition in the
  schema, and a function for each API call described by "links".

  If the schema contains the following:

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
  defmacro defapi(api_module_name, app, json) do
    quote location: :keep, bind_quoted: binding() do
      unresolved = load_schema(json)
      ensure_definitions! unresolved
      endpoint_url = JSONHyperschema.Schema.endpoint!(unresolved)
      resolved_hyperschema = ExJsonSchema.Schema.resolve(unresolved)
      api_module = :"Elixir.#{api_module_name}"

      defmodule api_module do
        def endpoint do
          unquote(endpoint_url)
        end

        def env do
          Application.get_env(unquote(app), :api_config, %{})
        end

        def http_client do
          env()[:http_client] || HTTPoison
        end

        def env_headers do
          env()[:request_headers] || []
        end

        def request_headers do
          h = [
            "Accept": "application/json",
            "Content-Type": "application/json",
          ] ++ env_headers()
        end

        def request_options do
          env()[:request_options] || []
        end

        definitions_ref = [:root, "definitions"]
        definitions = ExJsonSchema.Schema.get_ref_schema(
          resolved_hyperschema, definitions_ref
        )
        Enum.each(
          definitions,
          fn ({resource_name, _definition}) ->
            defresource api_module, resource_name, resolved_hyperschema
          end
        )
      end
    end
  end

  @doc """
  Defines a module for a type (found in a JSON hyperschema definition) and
  defines a function for each of the type's links (via defaction).
  """
  defmacro defresource(api_module, name, resolved_hyperschema) do
    quote location: :keep, bind_quoted: binding() do
      resource_ref = [:root, "definitions", name]
      resource = ExJsonSchema.Schema.get_ref_schema(
        resolved_hyperschema, resource_ref
      )
      links = resource["links"] || []
      action_names = unique_action_names(links)
      hyperschema = resolved_hyperschema.schema
      schema = ExJsonSchema.Schema.resolve(JSONHyperschema.Schema.to_schema(hyperschema))
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
            {uri_path, params} = JSONPointer.parse(href, resolved_hyperschema)
            http_method = to_method(method)
            action_name = Enum.at(action_names, i)
            body_schema = if Map.has_key?(action, "schema") do
              # Get a micro schema for the call parameters
              JSONHyperschema.Schema.denormalize_fragment(action["schema"], schema)
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
          body_json = Jason.encode!(unquote(params_var))
          request(unquote(api_module), unquote(method), path, body_json)
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
        #{Jason.encode!(body_schema, space: 1, indent: 2)}
        ```
        """
      else
        action_docs
      end

      # 3. Finally, we can define the actual function:

      Module.put_attribute(__MODULE__, :doc, {1, action_docs})

      def unquote(:"#{name}")(unquote_splicing(method_params)) do
        unquote(path_assignment)
        unquote(validation_and_call)
      end
    end
  end

  @doc false
  def load_schema(json) do
    make_schema_draft4_compatible(json)
    |> Jason.decode!
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
  # Builds a series of action name candidates for each action
  # Removes items that are duplicated
  # Returns the simplest
  def unique_action_names(actions) do
    actions
    |> build_candidates_lists
    |> remove_nils
    |> remove_duplicates
    |> take_first
  end

  defp build_candidates_lists(actions) do
    Enum.map(
      Stream.with_index(actions),
      fn ({action, i}) ->
        basic = basic_action_name(action)
        [
          basic,
          name_from_description(action),
          name_from_title(action),
          add_position(basic, i) # failsafe
        ] |> Enum.uniq
      end
    )
  end

  defp remove_nils(lists) do
    Enum.map(
      lists,
      fn (list) ->
        Enum.filter(list, &(&1))
      end
    )
  end

  defp remove_duplicates(lists) do
    duplicates = duplicates(lists)
    Enum.map(
      lists,
      fn (list) ->
        Enum.filter(
          list,
          fn (item) -> Enum.find(duplicates, &(&1 == item)) == nil end
        )
      end
    )
  end

  defp duplicates(lists) do
    items =
      lists
      |> List.flatten
      |> Enum.sort

    Enum.reduce(
      items,
      {[], nil},
      fn (item, {dupes, previous}) ->
        if item == previous do
          {[item | dupes], item}
        else
          {dupes, item}
        end
      end
    )
    |> elem(0)
    |> Enum.uniq
  end

  defp take_first(lists) do
    Enum.map(lists, &hd/1)
  end

  defp add_position(name, position) do
    "#{name}_#{position}"
  end

  @doc false
  def basic_action_name(%{"rel" => "self", "method" => "GET"}), do: "get"
  def basic_action_name(%{"rel" => "self", "method" => "POST"}), do: "post"
  def basic_action_name(%{"rel" => "instances", "method" => "GET"}), do: "index"
  def basic_action_name(%{"rel" => rel}) do
    rel
    |> String.downcase
    |> String.split(" ")
    |> Enum.join("_")
  end

  defp name_from_description(%{"description" => description}) do
    description
    |> first_phrase
    |> phrase_to_snake_case
  end
  defp name_from_description(_) do
    nil
  end

  defp name_from_title(%{"title" => title}) do
    phrase_to_snake_case(title)
  end
  defp name_from_title(_) do
    nil
  end

  defp phrase_to_snake_case(phrase) do
    phrase
    |> to_lowercase_words
    |> words_to_snake_case
  end

  defp first_phrase(text) do
    text
    |> String.split(". ")
    |> hd
  end

  defp to_lowercase_words(phrase) do
    phrase
    |> String.downcase
    |> String.replace(~r([^a-z ]), "")
    |> String.strip
  end

  defp words_to_snake_case(words) do
    words
    |> String.split(" ")
    |> Enum.join("_")
  end

  @doc false
  def to_module_name(snake_case) do
    snake_case
    |> String.replace("-", "_")
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
  def request(api_module, method, path, body \\"") do
    url = api_module.endpoint <> path
    client = api_module.http_client()
    headers = api_module.request_headers()
    options = api_module.request_options()
    client.request(method, url, body, headers, options)
    |> handle_response
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 200, body: body}}) do
    {:ok, Jason.decode!(body)}
  end
  defp handle_response({:ok, %HTTPoison.Response{status_code: 201, body: body}}) do
    {:ok, Jason.decode!(body)}
  end
  defp handle_response({_, %HTTPoison.Response{status_code: _status_code, body: body}}) do
    {:error, Jason.decode!(body)}
  end
  defp handle_response({:error, %HTTPoison.Error{id: _id, reason: reason}}) do
    {:error, reason}
  end
end
