-- this test uses the official JSON schema test suite:
-- https://github.com/json-schema-org/JSON-Schema-Test-Suite

local json = require 'cjson'
--local lfs = require 'lfs'
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
  'spec/JSON-Schema-Test-Suite/tests/draft4/dependencies.json',
  'spec/extra/dependencies.json',
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
  'spec/JSON-Schema-Test-Suite/tests/draft4/enum.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/default.json',
  -- compound
  'spec/JSON-Schema-Test-Suite/tests/draft4/allOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/anyOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/oneOf.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/not.json',
  -- links/refs
  'spec/JSON-Schema-Test-Suite/tests/draft4/ref.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/refRemote.json',
  'spec/JSON-Schema-Test-Suite/tests/draft4/definitions.json',
  'spec/extra/ref.json',
  -- Lua extensions
  'spec/extra/table.json',
  'spec/extra/function.lua',
}

local function readjson(path)
  if path:match('%.json$') then
    local f = assert(io.open(path))
    local body = json.decode(assert(f:read('*a')))
    f:close()
    return body
  elseif path:match('%.lua$') then
    return dofile(path)
  end
  error('cannot read ' .. path)
end

local external_schemas = {
  ['http://json-schema.org/draft-04/schema'] = readjson('spec/jsonschema.json'),
  ['http://localhost:1234/integer.json'] = readjson('spec/JSON-Schema-Test-Suite/remotes/integer.json'),
  ['http://localhost:1234/subSchemas.json'] = readjson('spec/JSON-Schema-Test-Suite/remotes/subSchemas.json'),
  ['http://localhost:1234/folder/folderInteger.json'] = readjson('spec/JSON-Schema-Test-Suite/remotes/folder/folderInteger.json'),
}

local options = {
  external_resolver = function(url)
    return external_schemas[url]
  end,
}

for _, descriptor in ipairs(supported) do
  for _, suite in ipairs(readjson(descriptor)) do
    local skipped = blacklist[suite.description] or {}
    if skipped ~= true then
      describe(suite.description, function()
        local schema = suite.schema
        local validator
        before(function()
          local val, err = jsonschema.generate_validator(schema, options)
          assert_success(val, err)
          assert_type(val, 'function')
          validator = val
          package.loaded.valcode = jsonschema.generate_validator_code(schema, options)
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
