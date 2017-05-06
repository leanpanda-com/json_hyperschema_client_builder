defmodule JSONPointerTestData do
  def unresolved do
    %{
      "definitions" => %{
        "thing" => %{
          "definitions" => %{
            "weight" => %{"type" => "number"}
          }
        },
        "with-hyphen" => %{
          "definitions" => %{
            "attr-name" => %{"type" => "string"}
          }
        }
      }
    }
  end

  def schema do
    ExJsonSchema.Schema.resolve(unresolved())
  end

  def root_uri, do: "/"

  def simple_uri, do: "/foo/bar"

  def thing_pointer, do: "#/definitions/thing"

  def thing_weight_pointer, do: "#/definitions/thing/definitions/weight"

  def thing_weight_variable, do: :thing_weight

  def uri_with_pointer do
    "/foo/{(#{URI.encode_www_form(thing_weight_pointer())})}/bar"
  end

  def with_pointer_template do
    "/foo/\#{#{thing_weight_variable()}}/bar"
  end

  def uri_with_non_attribute_pointer do
    "/foo/{(#{URI.encode_www_form(thing_pointer())})}/bar"
  end

  def hyphenated_pointer, do: "#/definitions/with-hyphen/definitions/attr-name"

  def underscored_variable, do: :with_hyphen_attr_name

  def uri_with_hyphens do
    "/foo/{(#{URI.encode_www_form(hyphenated_pointer())})}/bar"
  end

  def underscored_template do
    "/foo/\#{#{underscored_variable()}}/bar"
  end
end

defmodule JSONPointerTest do
  use ExUnit.Case, async: true
  import JSONPointerTestData

  describe ".parse/2" do
    test "if the URI does not contain JSON pointers, it returns the URI" do
      assert JSONPointer.parse(simple_uri(), schema()) == {simple_uri(), []}
    end

    test "it handles the root path" do
      assert JSONPointer.parse(root_uri(), schema()) == {root_uri(), []}
    end

    test "it extracts pointers as type + attribute" do
      assert JSONPointer.parse(uri_with_pointer(), schema()) ==
        {with_pointer_template(), [thing_weight_variable()]}
    end

    test "it handles hyphenated types and attributes" do
      assert JSONPointer.parse(uri_with_hyphens(), schema()) ==
        {underscored_template(), [underscored_variable()]}
    end

    test "it fails if the pointer does not reference a type's attribute" do
      assert_raise(
        ArgumentError,
        ~r(Don't know how to transform),
        fn -> JSONPointer.parse(uri_with_non_attribute_pointer(), schema()) end
      )
    end
  end
end
