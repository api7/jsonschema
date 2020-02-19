-- JSON schema validator benchmarking tool

local json = require 'cjson'
local time = require 'posix.time'
local jsonschema = require 'jsonschema'

local clock_gettime = time.clock_gettime
local CLOCK_PROCESS_CPUTIME_ID = time.CLOCK_PROCESS_CPUTIME_ID
local function timer()
  local start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID)
  return function()
    local cur = clock_gettime(CLOCK_PROCESS_CPUTIME_ID)
    return (cur.tv_sec + cur.tv_nsec/1e9) - (start.tv_sec + start.tv_nsec/1e9)
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
  ['minLength validation'] = {
    ['one supplementary Unicode code point is not long enough'] = true, -- unicode handling
  },
  ['maxLength validation'] = {
    ['two supplementary Unicode code points is long enough'] = true, -- unicode handling
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

  -- not support: an external resolver is required
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/refRemote.json',
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/ref.json',
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/definitions.json',

  -- not support: todo
  -- 'spec/JSON-Schema-Test-Suite/tests/draft7/if-then-else.json',
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
