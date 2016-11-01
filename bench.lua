-- JSON schema validator benchmarking tool

local json = require 'cjson'
local time = require 'posix.time'
local jsonschema = require 'jsonschema-jit'

local mrandom = math.random
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
}

local supported = {
  'spec/extra/sanity.json',
  'spec/extra/empty.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/type.json',
  -- objects
  'spec/JSON-Schema-Test-Suite/tests/draft4/properties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/required.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/additionalProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/patternProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minProperties.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxProperties.json',
  -- TODO: dependencies
  -- strings
  'spec/JSON-Schema-Test-Suite/tests/draft4/minLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxLength.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/pattern.json',
  -- numbers
  'spec/JSON-Schema-Test-Suite/tests/draft4/multipleOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minimum.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maximum.json',
  -- lists
  'spec/JSON-Schema-Test-Suite/tests/draft4/items.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/additionalItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/minItems.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/maxItems.json',
  --'spec/JSON-Schema-Test-Suite/tests/draft4/uniqueItems.json',
  -- misc
  -- 'spec/JSON-Schema-Test-Suite/tests/draft4/enum.json',
}

local function decode_descriptor(path)
  local f = assert(io.open(path))
  local testsuite = json.decode(assert(f:read('*a')))
  f:close()
  return ipairs(testsuite)
end

local NRUNS = assert(tonumber(arg[1]), 'run count required')

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
        --if case.valid then
          ncases = ncases+1
          cases[ncases] = { validator, case.data }
        --end
      end
    end
  end
end
print('testcases loaded:', loadtimer())

local runtimer = timer()
for i=1, NRUNS do
  local case = cases[mrandom(ncases)]
  case[1](case[2])
end
print('run ' .. NRUNS .. ' validations:', runtimer())
