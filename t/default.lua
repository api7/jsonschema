local ffi = require('ffi')
local jsonschema = require 'jsonschema'
----------------------------------------------------- test case 1
local rule = {
    type = "object",
    properties = {
        rule = {
            type = "array",
            default = {1, 2, 3},
        },
        base = {type = "string", default = "xxxxxxxx"}
    }
}

-- local code = jsonschema.generate_validator_code(rule)
-- print(code)

local validator = jsonschema.generate_validator(rule)
assert(rule.id == nil, "fail: schema is polluted")

local conf = {}
local ok = validator(conf)

if not ok then
  ngx.say("fail: check default value")
  return
end

if not conf.rule then
  ngx.say("fail: missing default value")
  return
end

----------------------------------------------------- test case 2
rule = {
  type = "object",
  properties = {
    username = { type = "string" },
    passwd = { type = "string" },
  },
  oneOf = {
      {required = {"username", "passwd"}},
      {required = {}}
  }
}

validator = jsonschema.generate_validator(rule)

local ok, err = validator({passwd = "passwd", username = "name"})
if not ok then
  ngx.say("fail: check default value: ", err)
end

ok, err = validator({})
if not ok then
  ngx.say("fail: check default value: ", err)
end

ok = validator({passwd = "passwd"})
if ok then
  ngx.say("fail: expect to fail")
end

ngx.say("passed: table value as default value")

----------------------------------------------------- test case 3
local rule = {
  type = "array",
  uniqueItems = true
}

validator = jsonschema.generate_validator(rule)

local data = {}
for i = 1, 1000 * 500 do
  data[i] = i
end

ngx.update_time()
local start_time = ngx.now()

local ok, err = validator(data)
if not ok then
  ngx.say("fail: check uniqueItems array: ", err)
end

ngx.update_time()
if ngx.now() - start_time > 0.1 then
  ngx.say("fail: check uniqueItems array take more than 0.1s")
  ngx.exit(-1)
end

ngx.say("passed: check uniqueItems array")

----------------------------------------------------- test case 4
local rule = {
  type = "array",
  uniqueItems = true
}

validator = jsonschema.generate_validator(rule)

local data = {}
for i = 1, 1000 * 500 do
  if i < 100 then
    data[i] = {a=i}
  else
    data[i] = i
  end
end

ngx.update_time()
local start_time = ngx.now()
local ok, err = validator(data)
if not ok then
  ngx.say("fail: check uniqueItems array with few table items: ", err)
end

ngx.update_time()
if ngx.now() - start_time > 0.1 then
  ngx.say("fail: check uniqueItems array with few table items take more than 0.1s")
  ngx.exit(-1)
end
ngx.say("passed: check uniqueItems array with few table items")

----------------------------------------------------- test case 5
local rule = {
    id = "root:/",
    type = "object",
    properties = {
        base = {type = "string", default = "xxxxxxxx"}
    }
}

local validator = jsonschema.generate_validator(rule)
assert(rule.id == "root:/", "fail: schema id is removed")

----------------------------------------------------- test case 6
local rule = {
    type = "object",
    properties = {
        foo = {type = "boolean", default = false}
    }
}

local validator = jsonschema.generate_validator(rule)
local t = {}
local ok, err = validator(t)
if not ok then
  ngx.say("fail: inject default false value: ", err)
  return
end
assert(t.foo == false, "fail: inject default false value")

----------------------------------------------------- test int64
local rule = {
  type = "object",
  properties = {
      foo = "integer"
  }
}

local validator = jsonschema.generate_validator(rule)
local t = {
  foo = 1ULL
}
local ok, err = validator(t)
assert(ok, ("fail: failed to check uint64: %s"):format(err))
ngx.say("passed: pass check uint64")

local t = {
  foo = -2LL
}
local ok, err = validator(t)
assert(ok, ("fail: failed to check int64: %s"):format(err))
ngx.say("passed: pass check int64")

---cdata format
ffi.cdef[[
  union bar { int i;};
]]

local t = {
  foo = ffi.new("union bar", {})
}

local ok = validator(t)
assert(ok~=nil, "fail: failed to negative check of int64")
ngx.say("passed: pass negative check of int64")

----------------------------------------------------- test case 7
-- check string len
-- issue #61
local cases = {
    {"abcd", 4},
    {"☺☻☹", 3},
    {"1,2,3,4", 7},
    {"\xff", 1},
    {"\xc2\x80", 1},
    {"\xe0\x00", 2},
    {"\xe2\x80a", 3},
    {"\xed\x80\x80", 1},
    {"\xf0\x80", 2},
    {"\xf4\x80", 2},
}

local schema = {}
for i, case in ipairs(cases) do
    schema.minLength = case[2]
    schema.maxLength = case[2]
    local validator = jsonschema.generate_validator(schema)
    local ok, err = validator(case[1])
    assert(ok, string.format("fail: validate case %d,  err: %s, ", i, err))
end
ngx.say("passed: check string len")

----------------------------------------------------- test case 8
-- test pattern with `%`
local host_pattern = [[^http(s)?:\/\/[a-zA-Z0-9-_.:\@%]+$]]
local rule = {
    type = "object",
    properties = {
        foo = {
            pattern = host_pattern,
        },
    },
}

local validator = jsonschema.generate_validator(rule)
local t = {
    foo = "http://#baidu.com"
}
local ok, err = validator(t)
assert(ok~=nil, ("pattern: failed to check pattern with `%%`: %s"):format(err))
ngx.say("passed: pass check pattern with `%`")

----------------------------------------------------- test case 9
-- regression: per-call `datatype` must not be shared across recursive calls.
-- Schemas like `{type=array, maxLength=N, items={type=string}}` used to crash
-- because the items recursion mutated the outer function's datatype variable,
-- causing the outer string-only `maxLength` check to run on the array value
-- and call `utf8_len` on a table.
local rule = {
    type = "array",
    maxLength = 10,
    items = { type = "string" },
}
local validator = jsonschema.generate_validator(rule)
local pcall_ok, valid, val_err = pcall(validator, { "a", "b", "c" })
assert(pcall_ok, "fail: validator threw an error: " .. tostring(valid))
assert(valid, "fail: validator returned false: " .. tostring(val_err))
ngx.say("passed: recursive datatype is not shared across calls")

----------------------------------------------------- test case 10
-- skip_validation: type bypass - string value passes integer schema
local skip_fn = function(val, schema)
    return type(val) == "string" and val:sub(1, 10) == "$secret://"
end

rule = {
    type = "object",
    properties = {
        host = { type = "string" },
        port = { type = "integer" },
        enabled = { type = "boolean" },
    },
    required = { "host", "port" },
}

validator = jsonschema.generate_validator(rule, { skip_validation = skip_fn })
ok, err = validator({ host = "$secret://vault/host", port = "$secret://vault/port", enabled = "$secret://vault/flag" })
assert(ok, "fail: skip_validation should bypass type checks: " .. tostring(err))
ngx.say("passed: skip_validation bypasses type checks")

----------------------------------------------------- test case 11
-- skip_validation: enum bypass
rule = {
    type = "object",
    properties = {
        scheme = { type = "string", enum = { "http", "https" } },
    },
}
validator = jsonschema.generate_validator(rule, { skip_validation = skip_fn })
ok, err = validator({ scheme = "$secret://vault/scheme" })
assert(ok, "fail: skip_validation should bypass enum: " .. tostring(err))
-- non-secret string should still be validated
ok, err = validator({ scheme = "ftp" })
assert(not ok, "fail: non-secret value should still fail enum")
ngx.say("passed: skip_validation bypasses enum but normal values validated")

----------------------------------------------------- test case 12
-- skip_validation: default values still set for nil fields
rule = {
    type = "object",
    properties = {
        host = { type = "string" },
        port = { type = "integer", default = 6379 },
    },
}
validator = jsonschema.generate_validator(rule, { skip_validation = skip_fn })
local conf = { host = "$secret://vault/host" }
ok, err = validator(conf)
assert(ok, "fail: skip_validation with defaults: " .. tostring(err))
assert(conf.port == 6379, "fail: default value should still be set")
ngx.say("passed: skip_validation preserves default values")

----------------------------------------------------- test case 13
-- skip_validation: nested object properties still validated
rule = {
    type = "object",
    properties = {
        upstream = {
            type = "object",
            properties = {
                host = { type = "string" },
                port = { type = "integer" },
            },
            required = { "host" },
        },
    },
}
validator = jsonschema.generate_validator(rule, { skip_validation = skip_fn })
-- nested secret ref should pass
ok, err = validator({ upstream = { host = "$secret://vault/host", port = "$secret://vault/port" } })
assert(ok, "fail: nested skip_validation: " .. tostring(err))
-- whole object as secret ref should pass
ok, err = validator({ upstream = "$secret://vault/upstream" })
assert(ok, "fail: object-level skip_validation: " .. tostring(err))
ngx.say("passed: skip_validation works for nested objects")

----------------------------------------------------- test case 14
-- skip_validation: array items bypass
rule = {
    type = "object",
    properties = {
        tags = {
            type = "array",
            items = { type = "string", minLength = 3 },
        },
    },
}
validator = jsonschema.generate_validator(rule, { skip_validation = skip_fn })
ok, err = validator({ tags = { "abc", "$secret://vault/tag" } })
assert(ok, "fail: array items skip_validation: " .. tostring(err))
ngx.say("passed: skip_validation works for array items")

----------------------------------------------------- test case 15
-- skip_validation: not configured - normal validation applies
rule = {
    type = "object",
    properties = {
        port = { type = "integer" },
    },
}
validator = jsonschema.generate_validator(rule)
ok, err = validator({ port = "$secret://vault/port" })
assert(not ok, "fail: without skip_validation, string should fail integer type check")
ngx.say("passed: without skip_validation, normal validation applies")

----------------------------------------------------- test case 16
-- skip_validation: schema-aware hook - only bypass for string-typed fields
-- This demonstrates using the schema parameter to make smart decisions:
-- secret refs in string fields bypass constraints (enum, pattern, format),
-- but secret refs in non-string fields (integer/boolean) are rejected.
local schema_aware_skip = function(val, schema)
    if type(val) ~= "string" or val:sub(1, 10) ~= "$secret://" then
        return false
    end
    -- Only bypass when the schema expects a string type.
    -- For non-string fields, do not skip — we don't allow string
    -- placeholders in integer/boolean/object fields at validation time.
    if not schema or schema.type ~= "string" then
        return false
    end
    return true
end

rule = {
    type = "object",
    properties = {
        host = { type = "string", pattern = "^[a-z]+%.com$" },
        scheme = { type = "string", enum = { "http", "https" } },
        port = { type = "integer", minimum = 1, maximum = 65535 },
        enabled = { type = "boolean" },
    },
}
validator = jsonschema.generate_validator(rule, { skip_validation = schema_aware_skip })
-- secret ref in string+pattern field: bypassed (schema.type == "string")
ok, err = validator({ host = "$secret://vault/host" })
assert(ok, "fail: schema-aware skip should bypass string+pattern: " .. tostring(err))
-- secret ref in string+enum field: bypassed (schema.type == "string")
ok, err = validator({ scheme = "$secret://vault/scheme" })
assert(ok, "fail: schema-aware skip should bypass string+enum: " .. tostring(err))
-- secret ref in integer field: NOT bypassed (schema.type == "integer")
ok, err = validator({ port = "$secret://vault/port" })
assert(not ok, "fail: schema-aware skip should NOT bypass integer field")
-- secret ref in boolean field: NOT bypassed (schema.type == "boolean")
ok, err = validator({ enabled = "$secret://vault/flag" })
assert(not ok, "fail: schema-aware skip should NOT bypass boolean field")
-- non-secret invalid enum value: still fails
ok, err = validator({ scheme = "ftp" })
assert(not ok, "fail: non-secret should still fail enum")
ngx.say("passed: skip_validation schema-aware hook only skips string-typed fields")
