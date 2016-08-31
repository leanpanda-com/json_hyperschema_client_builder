defmodule JSONPointer do
  @doc """
  Takes a URI, optionally containing JSON pointers, and an ExJsonSchema
  resolved schema and returns a 2-element tuple containing a path template,
  and the variables to insert in the template.

  > parse(
    "/foo/{(%23%2Fdefinitions%2Fthing%2Fdefinitions%2Fweight)}/bar", schema
  )
  {"/foo/\#{bar}", [:bar]}
  """
  def parse(uri, schema) do
    parts = String.split(uri, "/")
    do_parse(schema, parts, [], [])
  end

  defp do_parse(_schema, [], [], _rparams) do
    {"/", []}
  end
  defp do_parse(_schema, [], rpath, rparams) do
    {"/" <> Path.join(Enum.reverse(rpath)), Enum.reverse(rparams)}
  end
  defp do_parse(schema, [element|parts], rpath, rparams) do
    if String.starts_with?(element, "{(%23") do
      uri = String.slice(element, 2, String.length(element) - 4)
      |> URI.decode
      ["#" | ref] = String.split(uri, "/")
      resolved_path = resolve_ref([:root] ++ ref, schema)
      name = path_to_name(resolved_path)
      do_parse(schema, parts, ["\#{" <> name <> "}"|rpath], [:"#{name}"|rparams])
    else
      do_parse(schema, parts, [element|rpath], rparams)
    end
  end

  defp resolve_ref(ref, schema) do
    target = ExJsonSchema.Schema.get_ref_schema(schema, ref)
    if is_ref?(target) do
      resolve_ref(target["$ref"], schema)
    else
      ref
    end
  end

  defp path_to_name([:root, "definitions", type, "definitions", attribute]) do
    "#{type}_#{attribute}"
    |> String.replace("-", "_")
  end
  defp path_to_name([:root|rest]) do
    joined = "#/" <> Enum.join(rest, "/")
    message = "Don't know how to transform '#{joined}' into a name"
    raise ArgumentError, message: message
  end

  defp is_ref?(node) do
    Map.has_key?(node, "$ref")
  end
end
