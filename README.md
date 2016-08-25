# JSONHyperschema.ClientBuilder

Creates an HTTP Client based on a JSON Hyperschema.

Usage:

```elixir
defapi "My.Client", schema_json
```

Where:
* `"My.Client"` becomes the top-level module,
* `schema_json` is the schema as a JSON string.

Each `definition` in the schema is transformed into a sub-module of the
top-level module.
Each `link` definition becomes a function inside this module.
URL parameters become parameters to the function, and (when appropriate),
the final parameter is `body`, which is sent as the body of the HTTP request.
The body is checked against the schema before being sent, and the function
returns a tuple with `{:error, [...messages...]}` if it is not valid.

## Installation

1. Add `json_hyperschema_client_builder` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:json_hyperschema_client_builder, "~> 0.1.0"}]
end
```

# References

## Similar Projects

* heroics - Generates Ruby code from JSON hyperschemas,
* ??? - Go
