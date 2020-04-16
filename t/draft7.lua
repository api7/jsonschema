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
  ['propertyNames validation'] = {  -- todo
    ['some property names invalid'] = true
  },
  ['contains keyword validation'] = {
    ['not array is valid'] = true
  },
  -- not support: an external resolver is required
  ['remote ref, containing refs itself'] = true,
  ['Recursive references between schemas'] = true,
  ['Location-independent identifier with absolute URI'] = true,
  ['Location-independent identifier with base URI change in subschema'] = true,
}

local supported = {
  'spec/extra/sanity.json',
  'spec/extra/empty.json',
  "spec/extra/dependencies.json",
  "spec/extra/table.json",
  "spec/extra/ref.json",
  "spec/extra/format.json",
  "spec/extra/default.json",

  'spec/JSON-Schema-Test-Suite/tests/draft7/type.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/default.json',
  'spec/JSON-Schema-Test-Suite/tests/draft6/dependencies.json',

  -- -- objects
  'spec/JSON-Schema-Test-Suite/tests/draft7/properties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/required.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/additionalProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/patternProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/minProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/maxProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/propertyNames.json',

  -- boolean
  'spec/JSON-Schema-Test-Suite/tests/draft7/boolean_schema.json',

  -- strings
  'spec/JSON-Schema-Test-Suite/tests/draft7/minLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/maxLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/pattern.json',
  -- numbers
  'spec/JSON-Schema-Test-Suite/tests/draft7/multipleOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/minimum.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/maximum.json',
  "spec/JSON-Schema-Test-Suite/tests/draft7/exclusiveMaximum.json",
  "spec/JSON-Schema-Test-Suite/tests/draft7/exclusiveMinimum.json",
  -- lists
  'spec/JSON-Schema-Test-Suite/tests/draft7/items.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/additionalItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/minItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/maxItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/uniqueItems.json',
  -- misc
  'spec/JSON-Schema-Test-Suite/tests/draft7/allOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/anyOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/oneOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/not.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/enum.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/format.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/const.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/contains.json',
  'spec/JSON-Schema-Test-Suite/tests/draft7/if-then-else.json',

  -- ref
  'spec/JSON-Schema-Test-Suite/tests/draft7/ref.json',
  -- not support: an external resolver is required
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/refRemote.json',
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/definitions.json',
}
-- supported = {
--   'spec/JSON-Schema-Test-Suite/tests/draft7/dependencies.json',
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
      local ok, validator = pcall(jsonschema.generate_validator, suite.schema, {
        name = suite.description,
      })
      if not ok then
        error("failed to generate validator for case " .. suite.description .. ", err: " .. validator)
      end
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
