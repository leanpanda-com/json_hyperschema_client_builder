defmodule JSONPointer do
  def parse(href, schema) do
    parts = String.split(href, "/")
    do_parse(schema, parts, [], [])
  end

  # TODO: document this, including refs to JSON schema docs
  # returns {"/foo/#{bar}", [:foo]}
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
  end
  defp path_to_name([:root|rest]) do
    joined = Enum.join(rest, ", ")
    raise ArgumentError, message: "Don't know how to transform #{joined} into a name"
  end

  defp is_ref?(node) do
    Map.has_key?(node, "$ref")
  end
end
