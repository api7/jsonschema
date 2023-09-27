# jsonschema

A pure Lua JSON Schema validator library for Lua/LuaJIT.

Validation is neither bound nor limited to JSON and can be used to validate other key-value data formats like [Lua tables](https://www.lua.org/pil/2.5.html), [msgpack](https://msgpack.org/index.html), and [bencode](https://en.wikipedia.org/wiki/Bencode).

The library is designed to validate incoming HTTP requests and is quite performant. Underneath, the library transforms the given schema to a pure Lua function on-the-fly.

We are currently improving the library to be as JIT-friendly as possible.

Thanks to [Julien Desgats](https://github.com/jdesgats) for his work on [ljsonschema](https://github.com/jdesgats/ljsonschema) on top which this project is built upon. This project is a reimplementation that makes it much faster in OpenResty environments by using specific optimization methods.

## Supported versions

| Specification version                                               | Supported? |
| ------------------------------------------------------------------- | ---------- |
| < Draft 4                                                           | ❌         |
| [Draft 4](https://json-schema.org/specification-links.html#draft-4) | ✅         |
| Draft 5                                                             | ❌         |
| [Draft 6](https://json-schema.org/specification-links.html#draft-6) | ✅         |
| [Draft 7](https://json-schema.org/specification-links.html#draft-7) | ✅         |

## Installation

This library supports Lua versions 5.2 and 5.3, and LuaJIT version 2.1 beta.

To install the library via LuaRocks:

```shell
luarocks install jsonschema
```

> [!NOTE]
> This library references the PCRE regex library.
>
> If you use the LuaJIT of OpenResty, it will automatically use the built in `ngx.re.find` function. But if you use Lua versions 5.2, 5.3 or LuaJIT version 2.1 beta, it will use the function `lrexlib-pcre` instead.
>
> This library also relies on [net-url](https://luarocks.org/modules/golgote/net-url) library and it should be installed.

## Development

To build this library locally and run the tests:

```shell
git submodule update --init --recursive
make dev
make test
```

## Usage

```lua
local jsonschema = require 'jsonschema'

-- Note: Cache the result of the schema compilation as this is quite expensive
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

Some advanced features of JSON Schema cannot be implemented using the standard library and requires third-party libraries to work.

In order to not bloat this library for simple usage, extension points are provided. The `generate_validator` takes in a table argument that can be used to customize the generated parser:

```lua
local v = jsonschema.generate_validator(schema, {
    -- A value used to check null elements in the validated documents
    -- Defaults to `cjson.null` (if available) or `nil`
    null = null_token,

    -- Function called to match patterns, defaults to `ngx.re.find` in OpenResty
    -- or `rex.find` from lrexlib-pcre on other occassions
    -- The pattern given here will follow the ECMA-262 specification
    match_pattern = function(string, patt)
        return ... -- boolean value
    end,

    -- Function called to resolve external schemas
    -- Called with the full URL to fetch (without the fragment part) and must return the corresponding schema as a Lua table
    -- No default implementation: this function must be provided if resolving external schemas is required
    external_resolver = function(url)
        return ... -- Lua table
    end,

    -- Name when generating the validator function
    -- Might ease debugging as it will appear in stack traces
    name = "myschema",
})
```

## Differences with JSONSchema

Due to the limitations of Lua, supporting the JSON Schema specification completely is difficult. Some of these limitations can be overcome using the extension points mentioned above while some limitations still exist:

- Empty tables and empty arrays are the same for Lua.

On the other hand, some extra features are supported:

- The type `table` can be used to match arrays or objects. It is much faster than `array` or `object` as it does not involve walking the table to find out if it's a sequence or a hash.
- The type `function` can be used to check for functions.
