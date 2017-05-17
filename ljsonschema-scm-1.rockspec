package = "ljsonschema"
version = "scm-1"
source = {
   url = "git://github.com/jdesgats/ljsonschema.git",
   branch = "master",
}
description = {
   summary = "JSON Schema data validator",
   detailed = [[
This module is  data validator the implements JSON Schema draft 4.
Given an JSON schema, it will generates a validator function that can be used
to validate any kind of data (not limited to JSON).
]],
   homepage = "https://github.com/jdesgats/ljsonschema",
   license = "MIT/X11"
}
dependencies = {
   "lua >= 5.1",
   "net-url",
}
build = {
   type = "builtin",
   modules = {
      jsonschema = "jsonschema/init.lua",
      ["jsonschema.store"] = "jsonschema/store.lua",
   }
}
