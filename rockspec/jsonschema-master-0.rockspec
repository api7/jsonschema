package = "jsonschema"
version = "master-0"
source = {
  url = "git://github.com/iresty/jsonschema.git",
  branch = "master",
}

description = {
  summary = "JSON Schema data validator",
  detailed = [[
This module is  data validator the implements JSON Schema draft 4.
Given an JSON schema, it will generates a validator function that can be used
to validate any kind of data (not limited to JSON).

Base on https://github.com/jdesgats/ljsonschema .
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
