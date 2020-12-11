package = "jsonschema"
version = "0.9.3-0"
source = {
  url = "git://github.com/api7/jsonschema.git",
  tag = "v0.9.3",
}

description = {
  summary = "JSON Schema data validator",
  detailed = [[
This library provides a jsonschema draft 4, draft 6, draft 7 validator for Lua/LuaJIT.
Given an JSON schema, it will generates a validator function that can be used
to validate any kind of data (not limited to JSON).
Base on https://github.com/jdesgats/jsonschema .
]],
  homepage = "https://github.com/iresty/jsonschema",
  license = "MIT"
}

dependencies = {
  "net-url",
}

build = {
  type = "builtin",
  modules = {
    ["jsonschema"] = "lib/jsonschema.lua",
    ["jsonschema.store"] = "lib/jsonschema/store.lua",
  }
}
