-- JSON schema validator benchmarking tool

local json = require 'cjson'
local jsonschema = require 'jsonschema'

local function timer()
  ngx.update_time()
  local start = ngx.now()
  return function()
    ngx.update_time()
    return ngx.now() - start
  end
end

local blacklist = {
  -- edge cases, not supported features
  ['object type matches objects'] = {
    ['an array is not an object'] = true, -- empty object/array confusion
  },
  ['array type matches arrays'] = {
    ['an object is not an array'] = true, -- empty object/array confusion
  },
  ['regexes are not anchored by default and are case sensitive'] = {
    ['recognized members are accounted for'] = true, -- uses a unsupported pattern construct
  },
  ['required validation'] = {
    ['ignores arrays'] = true
  },
  ['minProperties validation'] = {
    ['ignores arrays'] = true
  },
  ['exclusiveMinimum validation'] = {
    -- dropped in jsonschema draft6
    ['above the minimum is still valid'] = true,
    ['boundary point is invalid'] = true,
  },
  ['exclusiveMaximum validation'] = {
    -- droped in jsonschema draft6
    ['below the maximum is still valid'] = true,
    ['boundary point is invalid'] = true,
  },
}

local supported = {
  'spec/extra/sanity.json',
  'spec/extra/empty.json',
  "spec/extra/dependencies.json",
  "spec/extra/table.json",
  "spec/extra/ref.json",

  'spec/JSON-Schema-Test-Suite/tests/draft4/type.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/default.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/dependencies.json',

  -- objects
  'spec/JSON-Schema-Test-Suite/tests/draft4/additionalProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/properties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/required.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/patternProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxProperties.json',

  -- strings
  'spec/JSON-Schema-Test-Suite/tests/draft4/minLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/pattern.json',
  -- numbers
  'spec/JSON-Schema-Test-Suite/tests/draft4/multipleOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minimum.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maximum.json',
  -- lists
  'spec/JSON-Schema-Test-Suite/tests/draft4/additionalItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/items.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/uniqueItems.json',
  -- misc
  'spec/JSON-Schema-Test-Suite/tests/draft4/allOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/anyOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/oneOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/not.json',

  -- not support: an external resolver is required
  -- 'spec/JSON-Schema-Test-Suite/tests/draft4/ref.json',

  -- not support: an external resolver is required
  -- 'spec/JSON-Schema-Test-Suite/tests/draft4/refRemote.json',
  -- 'spec/JSON-Schema-Test-Suite/tests/draft4/definitions.json',
}
-- supported = {
--   'spec/JSON-Schema-Test-Suite/tests/draft4/refRemote.json',
-- }

local function decode_descriptor(path)
  local f = assert(io.open(path))
  local testsuite = json.decode(assert(f:read('*a')))
  f:close()
  return ipairs(testsuite)
end

-- read all test cases
local loadtimer = timer()
local cases, ncases = {}, 0
for _, descriptor in ipairs(supported) do
  for _, suite in decode_descriptor(descriptor) do
    local skipped = blacklist[suite.description] or {}
    if skipped ~= true then
      local validator = jsonschema.generate_validator(suite.schema, {
        name = suite.description,
      })
      for _, case in ipairs(suite.tests) do
        if skipped[case.description] then
          print("skip suite case: [" .. suite.description .. "] -> [" .. case.description .. "]")
        else
          ncases = ncases+1
          cases[ncases] = {validator = validator, expect = case, suite_desc = suite.description}
        end
      end

      -- local code = jsonschema.generate_validator_code(suite.schema)
      -- print("------->\n", code)
    else
      print("skip suite case: [" .. suite.description .. "]")
    end
  end
end

print('testcases loaded: ', loadtimer())

local runtimer = timer()
for _, case in ipairs(cases) do
  local ok, err = case.validator(case.expect.data)
  if ok ~= case.expect.valid then
    print("validate res: ", ok, " err: ", err)
    print("case: ", json.encode(case.expect), " suite: ", case.suite_desc)
  end
end

print('validations: ', runtimer())
