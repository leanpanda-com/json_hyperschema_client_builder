# JSONHyperschema.ClientBuilder

Creates an HTTP Client based on a JSON Hyperschema.

# Installation

1. Add `json_hyperschema_client_builder` to your list of dependencies in
  `mix.exs`:

```elixir
def deps do
  [{:json_hyperschema_client_builder, "~> 0.6.0"}]
end
```

# Usage

```elixir
defapi "My.Client", :app_name, schema_json
```

Where:
* `"My.Client"` becomes the top-level module,
* `:app_name` is the `app` value from your mix project,
* `schema_json` is the schema as a JSON string.

Each `definition` in the schema is transformed into a sub-module of the
top-level module.
Each `link` definition becomes a function inside this module.
URL parameters become parameters to the function, and (when appropriate),
the final parameter is `body`, which is sent as the body of the HTTP request.
The body is checked against the schema before being sent, and the function
returns a tuple with `{:error, [...messages...]}` if it is not valid.

## Authentication

Currently only one schema of authentication is implemented: OAuth 2.0 bearer
tokens.

Inside your project's config, you can set the token on the generated model:

```
config :my_app, :api_config,
  %{headers: ["Authorization": "Bearer secret"]}
```

If you implement a login system, you can set the token at run time:

```
token = ...
Application.put_env(
  :my_app, :api_config, %{headers: ["Authorization": "Bearer #{secret}"]}
)
```

# Implementation

## Compilation

The JSON Hyperschema is loaded at compile time and produces an API module
via a series of macros.

## JSON Schema/Hyperschema Libraries

Currently, there is no Elixir module that handles resolving and validating
against JSON hyperschemas. This code cheats by replaceing "$schema" values
with the URL for the Draft 4 Schema, as it is the only one that `ex_json_schema`
handles.

# References

## Similar Projects

* [heroics][heroics_home] - Generates Ruby code from JSON hyperschemas,
* [Schematic][schematic_home] - Generates Go clients from JSON hyperschemas.

[heroics_home]: https://github.com/interagent/heroics
[schematic_home]: https://github.com/interagent/schematic
