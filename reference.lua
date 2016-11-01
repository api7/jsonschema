-- This module contains utility functions and classes for reference handling.
-- It is meant to be used only in compilation phase hence it is not a hot code
-- path, threfore not much effort should be spent to optimize it.

local       sformat,       schar,       sbyte =
      string.format, string.char, string.byte
local tconcat = table.concat
local mfloor = math.floor

local function percent_unescape(x)
  return schar(tonumber(x, 16))
end
local function percent_escape(c)
  return sformat('%%%02x', sbyte(c))
end
-- tilde escapes: see https://tools.ietf.org/html/rfc6901#section-3
local tilde_unescape = { ['~0']='~', ['~1']='/' }
local tilde_escape   = { ['~']='~0', ['/']='~1' }
local function urlunescape(fragment)
  local n = tonumber(part)
  if n and mfloor(n) == n and n >= 0 then
    return n+1
  end
  return fragment:gsub('%%(%x%x)', percent_unescape):gsub('~[01]', tilde_unescape)
end
local function urlescape(fragment)
  if type(fragment) == 'number' and mfloor(fragment) == fragment and fragment >= 1 then
    return tostring(fragment-1)
  end
  return fragment:gsub('[^0-9a-zA-Z-._~]', percent_escape):gsub('[~/]', tilde_escape)
end
local function urlnormalize(id, url) -- TODO: text uppercase vs lowercase percent escape, unnecessary escapes, ...
  local address, fragment = url:match('(.-)#(.*)')
  local parts = { '' }
  for p in fragment:gmatch('[^/]+') do
    parts[#parts+1] = urlescape(urlunescape(p))
  end
  fragment = tconcat(parts, '/')
  if address ~= '' then
    -- prepend the address prefix from id
    address = id:match('(.-)#') .. address
  end
  return sformat('%s#/%s', address, fragment), address ~= '' and address, fragment
end

-- FIXME: debug only
local function q(s) return sformat('%q', s) end

--
-- schema management
--

local ref_mt = {}
ref_mt.__index = ref_mt

-- returns a reference to a descendant node relative to the current node
function ref_mt:child(...)
  local schema = self.schema
  local path = { self.id, ... }
  assert(#path > 0, 'at least one argument is required')

  for i=2, #path do -- first item is already escaped/resolved
    schema = schema[path[i]]
    path[i] = urlescape(path[i])
    if type(schema) ~= 'table' then
      error('child node not found: ' .. tconcat(path, '/', 1, i))
    end
  end
  path = tconcat(path, '/')

  return setmetatable({
    _refman = self._refman,
    id = path,
    root = self.root,
    schema = schema,
  }, ref_mt)
end

-- value store management, allows to attach values to references and retrieve
-- them, even if the reference has beed obtained by another way
function ref_mt:get()
  return self._refman[self.id]
end
function ref_mt:set(v)
  self._refman[self.id] = v
end

function ref_mt:resolve()
  assert(self.schema['$ref'])
  if not self.schema['$ref'] then return self end
  local refman = self._refman
  local schema = self.schema
  local root = self.root
  local id = self.id

  local target, target_url, target_path
  -- TODO: detect loops
  while schema['$ref'] do
    target, target_url, target_path = urlnormalize(id, schema['$ref'])
    print('RESOLVE', schema['$ref'], target, target_url, q(target_path))
    if target_url then
      root = refman:fetch(target_url)
    end
    schema = root

    for part in target_path:gmatch('[^/]+') do
      print('WALK', part, urlunescape(part), schema[urlunescape(part)])
      schema = schema[urlunescape(part)]
      if not schema then
        error('failed to find schema pointer: ' .. schema['$ref'])
      end
    end
  end
  return setmetatable({
    _refman = self._refman,
    id = target,
    root = root,
    schema = schema,
  }, ref_mt)
end

local refman_mt = {}
refman_mt.__index = refman_mt

local function new_refman(schema, resolver)
  local root_id = schema.id or ''
  local self = setmetatable({
    _root_id = root_id,
    _schemas = {
      [root_id] = schema,
    },
    -- store of fully resolved known references, it maps the URI to an arbitrary
    -- value (see ref:get and ref:set)
    _refs = {},
    _resolver = resolver,
  }, refman_mt)
  return self
end

-- returs a reference to 
function refman_mt:root()
  local schema = self._schemas[self._root_id]
  return setmetatable({
    _refman = self,
    id = self._root_id .. '#',
    schema = schema,
    root = schema,
  }, ref_mt)
end

function refman_mt:fetch(id)
  if self._schemas[id] then
    return self._schemas[id]
  elseif not self._resolver then
    error('need an external resolver to resolve: ' .. id)
  end

  local schema = self._resolver(id)
  if not schema.id then
    -- set id if unset
    schema.id = id
  elseif schema.id ~= id then
    -- otherwise, check it actually match (mismatch leads to all sorts of weird issues)
    error(sformat('schema id mismatch: fetched %q, got %q', schema.id, id))
  end
  self._schemas[id] = schema
  return schema
end

return {
  refman = new_refman,
}

