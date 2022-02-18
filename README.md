jsonschema: JSON schema validator
===========================================

This library provides a JSON schema draft 4, draft 6, draft 7 validator for Lua/LuaJIT.
Note that even though it uses the JSON Schema semantics, it is neither bound or limited
to JSON. It can be used to validate saner key/value data formats as well (Lua
tables, msgpack, bencode, ...).

It has been designed to validate incoming data for HTTP APIs so it is decently
fast: it works by transforming the given schema into a pure Lua function
on-the-fly. Work is currently in progress to make it as JIT-friendly as
possible.

This project base on [ljsonschema](https://github.com/jdesgats/ljsonschema). Many thanks to the author `jdesgats` for the perfect work. The re-implementation is we need to support OpenResty env,
and we can use more optimization methods only available in OpenResty, which can make it run faster in OpenResty land.

Installation
------------

This module is pure Lua/LuaJIT project, it support Lua 5.2, Lua 5.3, LuaJIT 2.1 beta.

The preferred way to install this library is to use Luarocks:

    luarocks install jsonschema

Running the tests:

    git submodule update --init --recursive
    make dev
    make test

The project references the pcre regular library.

If you were using the LuaJIT of OpenResty, it will use the built-in `ngx.re.find` automatically.
But if you are using Lua 5.2, 5.3 or LuaJIT 2.1 beta, it will use `lrexlib-pcre` instead.

In addition, the project also relies on the `net_url` library, which you need to install anyway.

Usage
-----

### Getting started

```lua
local jsonschema = require 'jsonschema'

-- Note: do cache the result of schema compilation as this is a quite
-- expensive process
local myvalidator = jsonschema.generate_validator {
  type = 'object',
  properties = {
    foo = { type = 'string' },
    bar = { type = 'number' },
  },
}

print(myvalidator{ foo='hello', bar=42 })
```

### Advanced usage

Some advanced features of JSON Schema are not possible to implement using the
standard library and require third party libraries to be work.

In order to not force one particular library, and not bloat this library for
the simple schemas, extension points are provided: the `generate_validator`
takes a second table argument that can be used to customise the generated
parser.

```lua
local v = jsonschema.generate_validator(schema, {
    -- a value used to check null elements in the validated documents
    -- defaults to `cjson.null` (if available) or `nil`
    null = null_token,

    -- function called to match patterns, defaults to `ngx.re.find` in OpenResty
    -- or `rex.find` from lrexlib-pcre on other occassions.
    -- The pattern given here will obey the ECMA-262 specification.
    match_pattern = function(string, patt)
        return ... -- boolean value
    end,

    -- function called to resolve external schemas. It is called with the full
    -- url to fetch (without the fragment part) and must return the
    -- corresponding schema as a Lua table.
    -- There is no default implementation: this function must be provided if
    -- resolving external schemas is required.
    external_resolver = function(url)
        return ... -- Lua table
    end,

    -- name when generating the validator function, it might ease debugging as
    -- as it will appear in stack traces.
    name = "myschema",
})
```

Differences with JSONSchema
---------------------------

Due to the nature of the Lua language, the full JSON schema support is
difficult to reach. Some of the limitations can be solved using the advanced
options detailed previously, but some features are not supported (correctly)
at this time:

* Empty tables and empty arrays are the same from Lua point of view


On the other hand, some extra features are supported:

* The type `table` can be used to match arrays or objects, it is also much
  faster than `array` or `object` as it does not involve walking the table to
  find out if it's a sequence or a hash
* The type `function` can be used to check for functions

