-- this test uses the official JSON schema test suite:
-- https://github.com/json-schema-org/JSON-Schema-Test-Suite

local json = require 'cjson'
local lfs = require 'lfs'
local jsonschema = require 'jsonschema'

local telescope = require 'telescope'
telescope.make_assertion('success', "%s to be a success, got error '%s'", function(ok, err) return not not ok end)
telescope.make_assertion('failure', "a failure with error '%s', got (%s, %s)", function(exp, ok, err)
  return not ok and err == exp
end)
telescope.status_labels[telescope.status_codes.err]         = '\27[31;1mE\27[0m'
telescope.status_labels[telescope.status_codes.fail]        = '\27[31;1mF\27[0m'
telescope.status_labels[telescope.status_codes.pass]        = '\27[32mP\27[0m'
telescope.status_labels[telescope.status_codes.pending]     = '\27[34;1m?\27[0m'
telescope.status_labels[telescope.status_codes.unassertive] = '\27[33;1mU\27[0m'

-- the full support of JSON schema in Lua is difficult to achieve in some cases
-- so some tests from the official test suite fail, skip them.
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

  -- TODO: NOT YET IMPLEMENTED
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
  'spec/JSON-Schema-Test-Suite/tests/draft4/uniqueItems.json',
  -- misc
  -- 'spec/JSON-Schema-Test-Suite/tests/draft4/enum.json',

}

local function decode_descriptor(path)
  local f = assert(io.open(path))
  local testsuite = json.decode(assert(f:read('*a')))
  f:close()
  return ipairs(testsuite)
end

for _, descriptor in ipairs(supported) do
  for _, suite in decode_descriptor(descriptor) do
    local skipped = blacklist[suite.description] or {}
    if skipped ~= true then
      describe(suite.description, function()
        local schema = suite.schema
        local validator
        before(function()
          local val, err = jsonschema.generate_validator(schema)
          assert_success(val, err)
          assert_type(val, 'function')
          validator = val
        end)

        for _, case in ipairs(suite.tests) do
          if not skipped[case.description] then
            test(case.description, function()
              if case.valid then
                assert_true(validator(case.data))
              else
                assert_false(validator(case.data))
                -- TODO: test error message?
              end
            end) -- test
          end -- case skipped
        end -- for cases
      end) -- describe
    end -- suite skipped
  end -- for suite
end -- for descriptor
