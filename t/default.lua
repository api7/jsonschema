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
