local jsonschema = require 'jsonschema'

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
