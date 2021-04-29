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
