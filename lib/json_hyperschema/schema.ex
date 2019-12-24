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

  @doc "Removes `links` from all definitions"
  def to_schema(hyperschema) do
    simplified = Enum.reduce(
      hyperschema["definitions"],
      %{},
      fn ({name, definition}, acc) ->
        simple = remove_links(definition)
        Map.merge(acc, %{name => simple})
      end
    )
    %{hyperschema | "definitions" => simplified}
  end

  defp remove_links(definition) do
    Map.delete(definition, "links")
  end

  def denormalize_fragment(fragment, schema) do
    do_denormalize(fragment, schema)
  end

  defp do_denormalize(%{"$ref" => ref}, schema) do
    {:ok, fragment} = ExJsonSchema.Schema.get_fragment(schema, ref)
    denormalize_fragment(fragment, schema)
  end
  defp do_denormalize(attr = %{"type" => type}, _schema) when type == "string" or type == ["string"] do
    attr
  end
  defp do_denormalize(attr, schema) when is_map(attr) do
    Enum.reduce(
      attr,
      %{},
      fn({name, attr}, acc) ->
        resolved_key = do_denormalize(attr, schema)
        Map.merge(acc, %{name => resolved_key})
      end
    )
  end
  defp do_denormalize(attr, schema) when is_list(attr) do
    Enum.map(
      attr,
      fn(attr) ->
        do_denormalize(attr, schema)
      end
    )
  end
  defp do_denormalize(attr, _schema) do
    attr
  end
end
