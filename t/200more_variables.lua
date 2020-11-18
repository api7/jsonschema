local jsonschema = require 'jsonschema'

----------------------------------------------------- test case 1
local rule = {
      type = "object",
      properties = {}
}

for i = 1, 256 do
    rule.properties["key" .. i] = {
        type = "string"
    }
end

local status, err = pcall(jsonschema.generate_validator, rule)
if not status then
    ngx.say("fail: check 200 more variables: ", err)
end
ngx.say("passed: check 200 more variables")
