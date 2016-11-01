local reference = require 'reference'

describe('reference manager', function()
  test('basic path handling', function()
    local schema = {
      id = 'http://example.com',
      definitions = {
        foo = { type = 'object' },
        bar = { type = 'number' },
        ['foo bar'] = {
          properties = {
            baz = { type = 'array' },
          },
        },
      },
    }
    local refman = reference.refman(schema)
    local root = refman:root()
    assert_equal('http://example.com#', root.id)
    assert_equal(schema, root.schema)
    assert_equal(schema, root.root)

    local foo = root:child('definitions', 'foo')
    assert_equal('http://example.com#/definitions/foo', foo.id)
    assert_equal(schema.definitions.foo, foo.schema)
    assert_equal(schema, foo.root)

    local foobar = root:child('definitions', 'foo bar')
    assert_equal('http://example.com#/definitions/foo%20bar', foobar.id)
    local baz = foobar:child('properties', 'baz')
    assert_equal('http://example.com#/definitions/foo%20bar/properties/baz', baz.id)
  end)

  test('basic path handling (no ID)', function()
    local schema = {
      definitions = {
        foo = { type = 'object' },
      },
    }
    local refman = reference.refman(schema)
    local root = refman:root()
    assert_equal('#', root.id)
    assert_equal(schema, root.schema)
    assert_equal(schema, root.root)

    local foo = root:child('definitions', 'foo')
    assert_equal('#/definitions/foo', foo.id)
    assert_equal(schema.definitions.foo, foo.schema)
    assert_equal(schema, foo.root)
  end)

  test('array handling', function()
    -- arrays are 0-indexed in JS, and thus in reference urls too, check that
    -- the normalization is done
    local refman = reference.refman({
      items = {
        { type='string' },
        { type='number' },
      }
    })
    local root = refman:root()
    assert_equal('#/items/0', root:child('items', 1).id)
  end)

  test('value storage', function()
    local refman = reference.refman({
      definitions = {
        foo = { type = 'object' },
        bar = { type = 'number' },
      }
    })

    local root = refman:root()
    local foo = root:child('definitions', 'foo')
    local bar = root:child('definitions', 'bar')
    assert_nil(foo:get())
    assert_nil(bar:get())
    foo:set('foo value')
    bar:set('bar value')
    assert_equal('foo value', foo:get())
    assert_equal('bar value', bar:get())

    -- try to re-get the value
    assert_equal('foo value', root:child('definitions'):child('foo'):get())
  end)

  describe('external references', function()
    local external
    local function resolver(id)
      return external[id]
    end
    before(function()
      -- rebuild external schemas before each test, as tables might be modified
      external = {
        foo = { type = 'object' },
        complex = {
          definitions = {
            foo = { type = 'object' },
          },
        },
        ref = { ['$ref'] = 'foo#' },
        complex_ref = { ['$ref'] = 'complex#/definitions/foo' },
        loopa = { ['$ref'] = 'loopb#' },
        loopb = { ['$ref'] = 'loopa#' },
      }
    end)

    test('simple ref', function()
      local refman = reference.refman({ properties = { foo = { ['$ref'] = 'foo#' } } }, nil)
      print(require('inspect')(refman:root():child('properties', 'foo'):resolve()))
      assert_equal(external.foo, refman:root():child('properties', 'foo').schema)
    end)
  end)
end)
