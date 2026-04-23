package = "jsonschema"
version = "0.9.11-0"
source = {
  url = "git+https://github.com/api7/jsonschema.git",
  tag = "v0.9.11",
}

description = {
  summary = "JSON Schema data validator",
  detailed = [[
This module is a data validator that implements JSON Schema drafts 4, 6, and 7.
Given a JSON schema, it will generate a validator function that can be used
to validate any kind of data (not limited to JSON).

Based on https://github.com/jdesgats/ljsonschema .
]],
  homepage = "https://github.com/api7/jsonschema",
  license = "Apache License 2.0",
}

dependencies = {
  "net-url",
  "lrexlib-pcre = 2.9.1-1",
}

build = {
  type = "builtin",
  modules = {
    ["jsonschema"] = "lib/jsonschema.lua",
    ["jsonschema.store"] = "lib/jsonschema/store.lua",
  }
}
