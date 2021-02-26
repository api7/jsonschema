-- This module is a store for all schemas unused in a code context.
-- It is meant to deal with the id and $ref madness that JSON schema authors
-- managed to put together. Resolving JSON references involves full URI
-- parsing, absolute/relative URLs, scope management, id aliases, multipass
-- parsing (as you have to walk the document a first time to discover all ids)
-- and other niceties.
--
-- Don't try to find any logic in this code, there isn't: this is just an
-- implementation of [1] which is foreign to the concept of *logic*.
--
-- [1] http://json-schema.org/latest/json-schema-core.html#rfc.section.8

-- I gave up (for now) on doing a stripped down URI parser only for JSON schema
-- needs
local url = require 'net.url'
local schar = string.char

-- the net.url is kinda weird when some uri parts are missing (sometimes it is
-- nil, sometimes it is an empty string)
local function noe(s) return s == nil or s == '' end

-- fetching and parsing external schemas requires a lot of dependencies, and
-- depends a lot on the application ecosystem (e.g. piping curl,  LuaSocket,
-- cqueues, ...). Moreover, most sane schemas are self contained, so it is not
-- even useful.
-- So it is up to the user to provide a resolver if it's really needed
local function default_resolver(uri)
  error('an external resolver is required to fetch ' .. uri)
end

local function percent_unescape(x)
  return schar(tonumber(x, 16))
end
local tilde_unescape = { ['~0']='~', ['~1']='/' }
local function urlunescape(fragment)
  return fragment:gsub('%%(%x%x)', percent_unescape):gsub('~[01]', tilde_unescape)
end

-- attempt to translate a URI fragment part to a valid table index:
-- * if the part can be converted to number, that number+1 is returned to
--   compensate with Lua 1-based indices
-- * otherwise, the part is returned URL-escaped
local function decodepart(part)
  local n = tonumber(part)
  return n and (n+1) or urlunescape(part)
end


-- a reference points to a particular node of a particular schema in the store
local ref_mt = {}
ref_mt.__index = ref_mt

function ref_mt:child(items)
  if not (items and items[1]) then return self end
  local schema = self:resolve()
  for _, node in ipairs(items) do
    if schema[decodepart(node)] ~= nil then
      schema = schema[decodepart(node)]
    else
      error("failed to find schema by node")
    end
  end
  return setmetatable({ store=self.store, schema=schema }, ref_mt)
end

function ref_mt:resolve()
  local schema = self.schema

  if type(schema) ~= "table" then
    return schema
  end

  -- resolve references
  while schema['$ref'] do
    -- ok, this is a ref, but what kind of ref?!?
    local ctx = self.store:ctx(schema)
    local ref = url.parse(ctx.base.id):resolve(schema['$ref'])
    local fragment = ref.fragment

    -- get the target schema
    ref.fragment = nil
    schema = self.store:fetch(tostring(ref:normalize()))

    -- no fragment? just retrun the root
    if not fragment then
      return schema
    end

    -- maybe the fragment is a id alias
    local by_id = self.store:ctx(ctx.base).map[fragment]
    if by_id then
      schema = by_id
    else
      -- maybe not after all, walk the schema
      -- TODO: notrmalize path (if there is people mean enough to put '.' or
      -- '..' components)
      for part in fragment:gmatch('[^/]+') do
        part = decodepart(part)
        local new = schema[part]
        -- TODO: add test case
        if new == nil then
          error(string.format('reference not found: %s#%s (at %q)',
                              ref, fragment, part))
        end
        schema = new
      end
    end

    if type(schema) ~= "table" then
      return schema
    end
  end

  return schema
end


-- a store manage all currently required schemas
-- it is not exposed directly
local store_mt = {}
store_mt.__index = store_mt

function store_mt:ref(schema)
  return setmetatable({
    store = self,
    schema = schema,
  }, ref_mt)
end

-- store of additional metadata by schema table part, this is to avoid
-- modifying schema tables themselves. For now, we have
--
-- * `base`: refers to the base schema (e.g. for a nested subschema to find
--   its parent schema
-- * `map`: only for "root" schemas, maps indetifiers to subschemas
function store_mt:ctx(t)
  local c = self.ctx_store[t]
  if not c then
    c = {}
    self.ctx_store[t] = c
  end
  return c
end

function store_mt:fetch(uri)
  local schema = self.schemas[uri]
  if schema then return schema end

  -- schema not yet known
  schema = self.resolver(uri)
  if not schema then
    error('faild to fetch schema for: ' .. uri)
  end
  if not schema.id then
    schema.id = uri
  end
  self:insert(schema)
  return schema
end


-- functions used to walk a schema
local function is_schema(path)
  local n = #path
  local parent, grandparent = path[n], path[n-1]

  return n == 0 or -- root node
     parent == 'additionalItems' or
     parent == 'additionalProperties' or
     parent == 'items' or
     parent == 'not' or
     (type(parent) == 'number' and (
        grandparent == 'items' or
        grandparent == 'allOf' or
        grandparent == 'anyOf' or
        grandparent == 'oneOf'
     )) or
     grandparent == 'properties' or
     grandparent == 'patternProperties' or
     grandparent == 'definitions' or
     grandparent == 'dependencies'
end

function store_mt:insert(schema)
  local id = url.parse(assert(schema.id, 'id is required'))
  assert(noe(id.fragment), 'schema ids should not have fragments')
  schema.id = tostring(id:normalize())
  self.schemas[schema.id] = schema
  local base_id = id

  -- walk the schema to collect the ids and populate the base field in context
  local map = {}

  local function walk(s, p)
    -- handle '$id' keyword
    if s['$id'] then
        local u = url.parse(s['$id'])
        if u.schema ~= nil or u.fragment == nil then
            error("Only location independent id is supported. Unsupported $id: " .. s['$id'])
        end

        map[u.fragment] = self:ref(s).schema
    end

    local id = s.id
    if id and s ~= schema and is_schema(p) then
      -- there is an id, but it is not over: we have 2 different cases (!)
      --  1. the id is a fragment: it is some kind of an internal alias
      --  2. the id is an url (relative or absolute): resolve it using the
      --     current base and use that as a new base.
      if id:sub(1,1) == '#' then
        -- fragment (case 1)
        map[id.fragment] = self:ref(s)
      else
        -- relative url (case 2)
        -- FIXME: I'm sure it's broken because resolution scopes could be
        -- nested... but at the same time, who the hell would do this and it
        -- passes the tests so ¯\_(ツ)_/¯
        local resolved = base_id:resolve(id)
        assert(noe(resolved.fragment), 'fragment in relative id')
        s.id = tostring(resolved:normalize())
        return self:insert(s)
      end
    end

    self:ctx(s).base = schema
    for k, v in pairs(s) do
      if type(v) == 'table' and
        (type(k) == 'number' or (
          k ~= 'enum' and
          k:sub(1,1) ~= '_'
        ))
      then
        table.insert(p, k)
        walk(v, p)
        table.remove(p)
      end
    end
  end
  walk(schema, {})
  self:ctx(schema).map = map
  return self:ref(schema)
end

local function new(schema, resolver)
  local self = setmetatable({
    ctx_store = {}, -- used to store metadata about schema parts
    schemas = {},
    resolver = resolver or default_resolver,
  }, store_mt)

  schema.id = schema.id or 'root:'
  return self:insert(schema)
end

return {
  new = new,
}
