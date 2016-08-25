defmodule JSONHyperschema.Schema do
  defmodule MissingEndpointError do
    defexception message: "the schema does not definie and endpoint"
  end

  def endpoint!(schema) do
    endpoint(schema) |> raise_or_return_endpoint
  end

  def raise_or_return_endpoint({:ok, endpoint}), do: endpoint
  def raise_or_return_endpoint({:error, message}) do
    raise MissingEndpointError, message: message
  end

  def endpoint(%{"links" => links}) do
    Enum.find(links, fn (link) -> Map.get(link, "rel") == "self" end)
    |> handle_self_link
  end
  def endpoint(_) do
    {:error, "The schema does not have any links"}
  end

  defp handle_self_link(nil) do
    {:error, "The schema's links do not include 'self'"}
  end
  defp handle_self_link(%{"href" => href}), do: {:ok, href}
  defp handle_self_link(_) do
    {:error, "The schema's 'self' link does not include an 'href'"}
  end

  def denormalize_ref(ref, schema) do
    fragment = ExJsonSchema.Schema.get_ref_schema(schema, ref)
    do_denormalize(ref, fragment, schema)
  end

  defp do_denormalize(_ref, %{"$ref" => resolved}, schema) do
    denormalize_ref(resolved, schema)
  end
  defp do_denormalize(
        ref,
        attr = %{"type" => "object", "properties" => properties},
        schema
      ) do
    resolved_properties = Enum.reduce(
      properties,
      %{},
      fn({name, prop_attr}, props) ->
        property_ref = ref ++ ["properties", name]
        resolved_prop = do_denormalize(property_ref, prop_attr, schema)
        Map.merge(props, %{name => resolved_prop})
      end
    )
    %{attr | "properties" => resolved_properties}
  end
  defp do_denormalize(_ref, attr, _schema) do
    attr
  end
end
