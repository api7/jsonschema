local store = require 'jsonschema.store'
local loadstring = loadstring
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local unpack = unpack or table.unpack
local sformat = string.format
local mmax, mmodf = math.max, math.modf
local coro_wrap = coroutine.wrap
local coro_yield = coroutine.yield
local DEBUG = os and os.getenv and os.getenv('DEBUG') == '1'
local tab_concat = table.concat
local tab_insert = table.insert

-- default null token
local default_null = nil
do
  local ok, cjson = pcall(require, 'cjson')
  if ok then default_null = cjson.null end
end

--
-- Code generation
--

local generate_validator -- forward declaration

local codectx_mt = {}
codectx_mt.__index = codectx_mt

function codectx_mt:libfunc(globalname)
  local root = self._root
  local localname = root._globals[globalname]
  if not localname then
    localname = globalname:gsub('%.', '_')
    root._globals[globalname] = localname
    root:preface(sformat('local %s = %s', localname, globalname))
  end
  return localname
end

function codectx_mt:localvar(init, nres)
  local names = {}
  local nloc = self._nloc
  nres = nres or 1
  for i=1, nres do
    names[i] = sformat('var_%d_%d', self._idx, nloc+i)
  end

  self:stmt(sformat('local %s = ', tab_concat(names, ', ')), init or 'nil')
  self._nloc = nloc + nres
  return unpack(names)
end

function codectx_mt:param(n)
  self._nparams = mmax(n, self._nparams)
  return 'p_' .. n
end

function codectx_mt:label()
  local nlabel = self._nlabels + 1
  self._nlabels = nlabel
  return 'label_' .. nlabel
end

-- Returns an expression that will result in passed value.
-- Currently user vlaues are stored in an array to avoid consuming a lot of local
-- and upvalue slots. Array accesses are still decently fast.
function codectx_mt:uservalue(val)
  local slot = #self._root._uservalues + 1
  self._root._uservalues[slot] = val
  return sformat('uservalues[%d]', slot)
end

local function q(s) return sformat('%q', s) end

function codectx_mt:validator(path, schema)
  local ref = self._schema:child(path)
  local resolved = ref:resolve()
  local root = self._root
  local var = root._validators[resolved]
  if not var then
    var = root:localvar('nil')
    root._validators[resolved] = var
    root:stmt(sformat('%s = ', var), generate_validator(root:child(ref), resolved))
  end
  return var
end

function codectx_mt:preface(...)
  assert(self._preface, 'preface is only available for root contexts')
  for i=1, select('#', ...) do
    tab_insert(self._preface, (select(i, ...)))
  end
  tab_insert(self._preface, '\n')
end

function codectx_mt:stmt(...)
  for i=1, select('#', ...) do
    tab_insert(self._body, (select(i, ...)))
  end
  tab_insert(self._body, '\n')
end

-- load doesn't like at all empty string, but sometimes it is easier to add
-- some in the chunk buffer
local function yield_chunk(chunk)
  if chunk and chunk ~= '' then
    coro_yield(chunk)
  end
end

function codectx_mt:_generate()
  local indent = ''
  if self._root == self then
    for _, stmt in ipairs(self._preface) do
      yield_chunk(indent)
      if getmetatable(stmt) == codectx_mt then
        stmt:_generate()
      else
        yield_chunk(stmt)
      end
    end
  else
    coro_yield('function(')
    for i=1, self._nparams do
      yield_chunk('p_' .. i)
      if i ~= self._nparams then yield_chunk(', ') end
    end
    yield_chunk(')\n')
    indent = string.rep('  ', self._idx)
  end

  for _, stmt in ipairs(self._body) do
    yield_chunk(indent)
    if getmetatable(stmt) == codectx_mt then
      stmt:_generate()
    else
      yield_chunk(stmt)
    end
  end

  if self._root ~= self then
    yield_chunk('end')
  end
end

function codectx_mt:_get_loader()
  return coro_wrap(function()
    self:_generate()
  end)
end

function codectx_mt:as_string()
  local buf, n = {}, 0
  for chunk in self:_get_loader() do
    n = n+1
    buf[n] = chunk
  end
  return tab_concat(buf)
end

function codectx_mt:as_func(name, ...)
  local buf, n = {}, 0
  for chunk in self:_get_loader() do
    n = n + 1
    buf[n] = chunk
  end

  local loader, err = loadstring(tab_concat(buf, ""), 'jsonschema:' .. (name or 'anonymous'))
  if loader then
    local validator
    validator, err = loader(self._uservalues, ...)
    if validator then return validator end
  end

  -- something went really wrong
  if DEBUG then
    local line=1
    print('------------------------------')
    print('FAILED to generate validator: ', err)
    print('generated code:')
    print('0001: ' .. self:as_string():gsub('\n', function()
      line = line + 1
      return sformat('\n%04d: ', line)
    end))
    print('------------------------------')
  end
  error(err)
end

-- returns a child code context with the current context as parent
function codectx_mt:child(ref)
  return setmetatable({
    _schema = ref,
    _idx = self._idx + 1,
    _nloc = 0,
    _nlabels = 0,
    _body = {},
    _root = self._root,
    _nparams = 0,
  }, codectx_mt)
end

-- returns a root code context. A root code context holds the library function
-- cache (as upvalues for the child contexts), a preface, and no named params
local function codectx(schema, options)
  local self = setmetatable({
    _schema = store.new(schema, options.external_resolver),
    _id = schema.id,
    _path = '',
    _idx = 0,
    -- code generation
    _nloc = 0,
    _nlabels = 0,
    _preface = {},
    _body = {},
    _globals = {},
    _uservalues = {},
    -- schema management
    _validators = {}, -- maps paths to local variable validators
    _external_resolver = options.external_resolver,
  }, codectx_mt)
  self._root = self
  return self
end


--
-- Validator util functions (available in the validator context
--
local validatorlib = {}

-- TODO: this function is critical for performance, optimize it
-- Returns:
--  0 for objects
--  1 for empty object/table (these two are indistinguishable in Lua)
--  2 for arrays
function validatorlib.tablekind(t)
  local length = #t
  if length == 0 then
    if next(t) == nil then
      return 1 -- empty table
    else
      return 0 -- pure hash
    end
  end

  -- not empty, check if the number of items is the same as the length
  local items = 0
  for k, v in pairs(t) do items = items + 1 end
  if items == #t then
    return 2 -- array
  else
    return 0 -- mixed array/object
  end
end

-- used for unique items in arrays (not fast at all)
-- from: http://stackoverflow.com/questions/25922437
-- If we consider only the JSON case, this function could be simplified:
-- no loops, keys are only strings. But this library might also be used in
-- other cases.
local function deepeq(table1, table2)
   local avoid_loops = {}
   local function recurse(t1, t2)
      -- compare value types
      if type(t1) ~= type(t2) then return false end
      -- Base case: compare simple values
      if type(t1) ~= "table" then return t1 == t2 end
      -- Now, on to tables.
      -- First, let's avoid looping forever.
      if avoid_loops[t1] then return avoid_loops[t1] == t2 end
      avoid_loops[t1] = t2
      -- Copy keys from t2
      local t2keys = {}
      local t2tablekeys = {}
      for k, _ in pairs(t2) do
         if type(k) == "table" then table.insert(t2tablekeys, k) end
         t2keys[k] = true
      end
      -- Let's iterate keys from t1
      for k1, v1 in pairs(t1) do
         local v2 = t2[k1]
         if type(k1) == "table" then
            -- if key is a table, we need to find an equivalent one.
            local ok = false
            for i, tk in ipairs(t2tablekeys) do
               if deepeq(k1, tk) and recurse(v1, t2[tk]) then
                  table.remove(t2tablekeys, i)
                  t2keys[tk] = nil
                  ok = true
                  break
               end
            end
            if not ok then return false end
         else
            -- t1 has a key which t2 doesn't have, fail.
            if v2 == nil then return false end
            t2keys[k1] = nil
            if not recurse(v1, v2) then return false end
         end
      end
      -- if t2 has a key which t1 doesn't have, fail.
      if next(t2keys) then return false end
      return true
   end
   return recurse(table1, table2)
end
validatorlib.deepeq = deepeq


--
-- Validation generator
--

-- generate an expression to check a JSON type
local function typeexpr(ctx, jsontype, datatype, tablekind)
  -- TODO: optimize the type check for arays/objects (using NaN as kind?)
  if jsontype == 'object' then
    return sformat('%s == "table" and %s <= 1 ', datatype, tablekind)
  elseif jsontype == 'array' then
    return sformat(' %s == "table" and %s >= 1 ', datatype, tablekind)
  elseif jsontype == 'table' then
    return sformat(' %s == "table" ', datatype)
  elseif jsontype == 'integer' then
    return sformat(' (%s == "number" and %s(%s, 1.0) == 0.0) ',
      datatype, ctx:libfunc('math.fmod'), ctx:param(1))
  elseif jsontype == 'string' or jsontype == 'boolean' or jsontype == 'number' then
    return sformat('%s == %q', datatype, jsontype)
  elseif jsontype == 'null' then
    return sformat('%s == %s', ctx:param(1), ctx:libfunc('custom.null'))
  elseif jsontype == 'function' then
    return sformat(' %s == "function" ', datatype)
  else
    error('invalid JSON type: ' .. jsontype)
  end
end

generate_validator = function(ctx, schema)
  -- get type informations as they will be necessary anyway
  local datatype = ctx:localvar(sformat('%s(%s)',
    ctx:libfunc('type'), ctx:param(1)))
  local datakind = ctx:localvar(sformat('%s == "table" and %s(%s)',
    datatype, ctx:libfunc('lib.tablekind'), ctx:param(1)))

  if schema == true then
    ctx:stmt('do return true end')
    return ctx
  elseif schema == false then
    ctx:stmt('do return false, "expect false always" end')
    return ctx
  end

  -- type check
  local tt = type(schema.type)
  if tt == 'string' then
    -- only one type allowed
    ctx:stmt('if not (', typeexpr(ctx, schema.type, datatype, datakind), ') then')
    ctx:stmt(sformat('  return false, "wrong type: expected %s, got " .. %s', schema.type, datatype))
    ctx:stmt('end')
  elseif tt == 'table' then
    -- multiple types allowed
    ctx:stmt('if not (')
    for _, t in ipairs(schema.type) do
      ctx:stmt('  ', typeexpr(ctx, t, datatype, datakind), ' or')
    end
    ctx:stmt('false) then') -- close the last "or" statement
    ctx:stmt(sformat('  return false, "wrong type: expected one of %s, got " .. %s', tab_concat(schema.type, ', '),  datatype))
    ctx:stmt('end')
  elseif tt ~= 'nil' then error('invalid "type" type: got ' .. tt) end

  -- properties check
  if schema.properties or
     schema.additionalProperties ~= nil or
     schema.patternProperties or
     schema.minProperties or
     schema.maxProperties or
     schema.dependencies or
     schema.required
  then
    -- check properties, this differs from the spec as empty arrays are
    -- considered as object
    ctx:stmt(sformat('if %s == "table" and %s <= 1 then', datatype, datakind))

    -- switch the required keys list to a set
    local required = {}
    local dependencies = schema.dependencies or {}
    local properties = schema.properties or {}
    if schema.required then
      for _, k in ipairs(schema.required) do required[k] = true end
    end

    -- opportunistically count keys if we walk the table
    local needcount = schema.minProperties or schema.maxProperties
    if needcount then
      ctx:stmt(          '  local propcount = 0')
    end

    for prop, subschema in pairs(properties) do
      -- generate validator
      local propvalidator = ctx:validator({ 'properties', prop }, subschema)
      ctx:stmt(          '  do')
      ctx:stmt(sformat(  '    local propvalue = %s[%q]', ctx:param(1), prop))
      ctx:stmt(          '    if propvalue ~= nil then')
      ctx:stmt(sformat(  '      local ok, err = %s(propvalue)', propvalidator))
      ctx:stmt(          '      if not ok then')
      ctx:stmt(sformat(  "        return false, 'property %q validation failed: ' .. err", prop))
      ctx:stmt(          '      end')

      if dependencies[prop] then
        local d = dependencies[prop]
        if #d > 0 then
          -- dependency is a list of properties
          for _, depprop in ipairs(d) do
            ctx:stmt(sformat('      if %s[%q] == nil then', ctx:param(1), depprop))
            ctx:stmt(sformat("        return false, 'property %q is required when %q is set'", depprop, prop))
            ctx:stmt(        '      end')
          end
        else
          -- dependency is a schema
          local depvalidator = ctx:validator({ 'dependencies', prop }, d)
          -- ok and err are already defined in this block
          ctx:stmt(sformat('      ok, err = %s(%s)', depvalidator, ctx:param(1)))
          ctx:stmt(        '      if not ok then')
          ctx:stmt(sformat("        return false, 'failed to validate dependent schema for %q: ' .. err", prop))
          ctx:stmt(        '      end')
        end
      end

      if required[prop] then
        ctx:stmt(        '    else')
        ctx:stmt(sformat("      return false, 'property %q is required'", prop))
        required[prop] = nil
      end
      ctx:stmt(          '    end') -- if prop

      if subschema.default and
         (type(subschema.default) == "number" or
          type(subschema.default) == "string" or
          type(subschema.default) == "boolean") then
        local default = subschema.default
        if type(subschema.default) == "string" then
          default = sformat("%q", default)
        end
        ctx:stmt(        '    if propvalue == nil then')
        ctx:stmt(sformat('      %s[%q] = %s', ctx:param(1), prop, default))
        ctx:stmt(        '    end')
      end

      ctx:stmt(          '  end') -- do
    end

    -- check the rest of required fields
    for prop, _ in pairs(required) do
      ctx:stmt(sformat('  if %s[%q] == nil then', ctx:param(1), prop))
      ctx:stmt(sformat("      return false, 'property %q is required'", prop))
      ctx:stmt(        '  end')
    end

    -- check the rest of dependencies
    for prop, d in pairs(dependencies) do
      if not properties[prop] then
        if #d > 0 then
          -- dependencies are a list of properties
          for _, depprop in ipairs(d) do
            ctx:stmt(sformat('  if %s[%q] ~= nil and %s[%q] == nil then', ctx:param(1), prop, ctx:param(1), depprop))
            ctx:stmt(sformat("    return false, 'property %q is required when %q is set'", depprop, prop))
            ctx:stmt(        '  end')
          end
        else
          -- dependency is a schema
          local depvalidator = ctx:validator({ 'dependencies', prop }, d)
          ctx:stmt(sformat('  if %s[%q] ~= nil then', ctx:param(1), prop))
          ctx:stmt(sformat('    local ok, err = %s(%s)', depvalidator, ctx:param(1)))
          ctx:stmt(        '    if not ok then')
          ctx:stmt(sformat("      return false, 'failed to validate dependent schema for %q: ' .. err", prop))
          ctx:stmt(        '    end')
          ctx:stmt(        '  end')
        end
      end
    end

    -- patternProperties and additionalProperties
    local propset, addprop_validator -- all properties defined in the object
    if schema.additionalProperties ~= nil and schema.additionalProperties ~= true then
      -- TODO: can be optimized with a static table expression
      propset = ctx._root:localvar('{}')
      if schema.properties then
        for prop, _ in pairs(schema.properties) do
          ctx._root:stmt(sformat('%s[%q] = true', propset, prop))
        end
      end

      if type(schema.additionalProperties) == 'table' then
        addprop_validator = ctx:validator({ 'additionalProperties' }, schema.additionalProperties)
      end
    end

    -- patternProperties and additionalProperties are matched together whenever
    -- possible in order to walk the table only once
    if schema.patternProperties then
      local patterns = {}
      for patt, patt_schema in pairs(schema.patternProperties) do
        patterns[patt] = ctx:validator({ 'patternProperties', patt }, patt_schema )
      end

      ctx:stmt(sformat(    '  for prop, value in %s(%s) do', ctx:libfunc('pairs'), ctx:param(1)))
      if propset then
        ctx:stmt(          '    local matched = false')
        for patt, validator in pairs(patterns) do
          ctx:stmt(sformat('    if %s(prop, %q) then', ctx:libfunc('custom.match_pattern'), patt))
          ctx:stmt(sformat('      local ok, err = %s(value)', validator))
          ctx:stmt(        '      if not ok then')
          ctx:stmt(sformat("        return false, 'failed to validate '..prop..' (matching %q): '..err", patt))
          ctx:stmt(        '      end')
          ctx:stmt(        '      matched = true')
          ctx:stmt(        '    end')
        end
        -- additional properties check
        ctx:stmt(sformat(  '    if not (%s[prop] or matched) then', propset))
        if addprop_validator then
          -- the additional properties must match a schema
          ctx:stmt(sformat('      local ok, err = %s(value)', addprop_validator))
          ctx:stmt(        '      if not ok then')
          ctx:stmt(        "        return false, 'failed to validate additional property '..prop..': '..err")
          ctx:stmt(        '      end')
        else
          -- additional properties are forbidden
          ctx:stmt(        '      return false, "additional properties forbidden, found " .. prop')
        end
        ctx:stmt(          '    end') -- if not (%s[prop] or matched)
      else
        for patt, validator in pairs(patterns) do
          ctx:stmt(sformat('    if %s(prop, %q) then', ctx:libfunc('custom.match_pattern'), patt))
          ctx:stmt(sformat('      local ok, err = %s(value)', validator))
          ctx:stmt(        '      if not ok then')
          ctx:stmt(sformat("        return false, 'failed to validate '..prop..' (matching %q): '..err", patt))
          ctx:stmt(        '      end')
          ctx:stmt(        '    end')
        end
      end
      if needcount then
        ctx:stmt(          '    propcount = propcount + 1')
      end
      ctx:stmt(            '  end') -- for
    elseif propset then
      -- additionalProperties alone
      ctx:stmt(sformat(  '  for prop, value in %s(%s) do', ctx:libfunc('pairs'), ctx:param(1)))
      ctx:stmt(sformat(  '    if not %s[prop] then', propset))
      if addprop_validator then
        -- the additional properties must match a schema
        ctx:stmt(sformat('      local ok, err = %s(value)', addprop_validator))
        ctx:stmt(        '      if not ok then')
        ctx:stmt(        "        return false, 'failed to validate additional property '..prop..': '..err")
        ctx:stmt(        '      end')
      else
        -- additional properties are forbidden
        ctx:stmt(        '      return false, "additional properties forbidden, found " .. prop')
      end
      ctx:stmt(          '    end') -- if not %s[prop]
      if needcount then
        ctx:stmt(        '    propcount = propcount + 1')
      end
      ctx:stmt(          '  end') -- for prop
    elseif needcount then
      -- we might still need to walk the table to get the number of properties
      ctx:stmt(sformat(  '  for _, _  in %s(%s) do', ctx:libfunc('pairs'), ctx:param(1)))
      ctx:stmt(          '    propcount = propcount + 1')
      ctx:stmt(          '  end')
    end

    if schema.minProperties then
      ctx:stmt(sformat('  if propcount < %d then', schema.minProperties))
      ctx:stmt(sformat('    return false, "expect object to have at least %s properties"', schema.minProperties))
      ctx:stmt(        '  end')
    end
    if schema.maxProperties then
      ctx:stmt(sformat('  if propcount > %d then', schema.maxProperties))
      ctx:stmt(sformat('    return false, "expect object to have at most %s properties"', schema.maxProperties))
      ctx:stmt(        '  end')
    end

    ctx:stmt('end') -- if object
  end

  -- array checks
  if schema.items or schema.minItems or schema.maxItems or schema.uniqueItems then
    ctx:stmt(sformat('if %s == "table" and %s >= 1 then', datatype, datakind))

    -- this check is rather cheap so do it before validating the items
    -- NOTE: getting the size could be avoided in the list validation case, but
    --       this would mean validating items beforehand
    if schema.minItems or schema.maxItems then
      ctx:stmt(sformat(  '  local itemcount = #%s', ctx:param(1)))
      if schema.minItems then
        ctx:stmt(sformat('  if itemcount < %d then', schema.minItems))
        ctx:stmt(sformat('    return false, "expect array to have at least %s items"', schema.minItems))
        ctx:stmt(        '  end')
      end
      if schema.maxItems then
        ctx:stmt(sformat('  if itemcount > %d then', schema.maxItems))
        ctx:stmt(sformat('    return false, "expect array to have at least %s items"', schema.maxItems))
        ctx:stmt(        '  end')
      end
    end

    if schema.items and #schema.items > 0 then
      -- each item has a specific schema applied (tuple validation)

      -- From the section 5.1.3.2, missing an array with missing items is
      -- still valid, because... Well because! So we have to jump after
      -- validations whenever we meet a nil value
      local after = ctx:label()
      for i, ischema in ipairs(schema.items) do
        -- JSON arrays are zero-indexed: remove 1 for URI path
        local ivalidator = ctx:validator({ 'items', tostring(i-1) }, ischema)
        ctx:stmt(        '  do')
        ctx:stmt(sformat('    local item = %s[%d]', ctx:param(1), i))
        ctx:stmt(sformat('    if item == nil then goto %s end', after))
        ctx:stmt(sformat('    local ok, err = %s(item)', ivalidator))
        ctx:stmt(sformat('    if not ok then'))
        ctx:stmt(sformat('      return false, "failed to validate item %d: " .. err', i))
        ctx:stmt(        '    end')
        ctx:stmt(        '  end')
      end

      -- additional items check
      if schema.additionalItems == false then
        ctx:stmt(sformat('  if %s[%d] ~= nil then', ctx:param(1), #schema.items+1))
        ctx:stmt(        '      return false, "found unexpected extra items in array"')
        ctx:stmt(        '  end')
      elseif type(schema.additionalItems) == 'table' then
        local validator = ctx:validator({ 'additionalItems' }, schema.additionalItems)
        ctx:stmt(sformat('  for i=%d, #%s do', #schema.items+1, ctx:param(1)))
        ctx:stmt(sformat('    local ok, err = %s(%s[i])', validator, ctx:param(1)))
        ctx:stmt(sformat('    if not ok then'))
        ctx:stmt(sformat('      return false, %s("failed to validate additional item %%d: %%s", i, err)', ctx:libfunc('string.format')))
        ctx:stmt(        '    end')
        ctx:stmt(        '  end')
      end

      ctx:stmt(sformat(  '::%s::', after))
    elseif schema.items then
      -- all of the items has to match the same schema (list validation)
      local validator = ctx:validator({ 'items' }, schema.items)
      ctx:stmt(sformat('  for i, item in %s(%s) do', ctx:libfunc('ipairs'), ctx:param(1)))
      ctx:stmt(sformat('    local ok, err = %s(item)', validator))
      ctx:stmt(sformat('    if not ok then'))
      ctx:stmt(sformat('      return false, %s("failed to validate item %%d: %%s", i, err)', ctx:libfunc('string.format')))
      ctx:stmt(        '    end')
      ctx:stmt(        '  end')
    end

    -- TODO: this is slow as hell, could be optimized by storing value items
    -- in a spearate set, and calling deepeq only for references.
    if schema.uniqueItems then
      ctx:stmt(sformat('  for i=2, #%s do', ctx:param(1)))
      ctx:stmt(        '    for j=1, i-1 do')
      ctx:stmt(sformat('      if %s(%s[i], %s[j]) then', ctx:libfunc('lib.deepeq'), ctx:param(1), ctx:param(1)))
      ctx:stmt(sformat('        return false, %s("expected unique items but items %%d and %%d are equal", i, j)', ctx:libfunc('string.format')))
      ctx:stmt(        '      end')
      ctx:stmt(        '    end')
      ctx:stmt(        '  end')
    end
    ctx:stmt('end') -- if array
  end

  if schema.minLength or schema.maxLength or schema.pattern then
    ctx:stmt(sformat('if %s == "string" then', datatype))
    if schema.minLength then
      ctx:stmt(sformat('  if #%s < %d then', ctx:param(1), schema.minLength))
      ctx:stmt(sformat('    return false, %s("string too short, expected at least %d, got %%d", #%s)',
                       ctx:libfunc('string.format'), schema.minLength, ctx:param(1)))
      ctx:stmt(        '  end')
    end
    if schema.maxLength then
      ctx:stmt(sformat('  if #%s > %d then', ctx:param(1), schema.maxLength))
      ctx:stmt(sformat('    return false, %s("string too long, expected at most %d, got %%d", #%s)',
                       ctx:libfunc('string.format'), schema.maxLength, ctx:param(1)))
      ctx:stmt(        '  end')
    end
    if schema.pattern then
      ctx:stmt(sformat('  if not %s(%s, %q) then', ctx:libfunc('custom.match_pattern'), ctx:param(1), schema.pattern))
      ctx:stmt(sformat('    return false, %s([[failed to match pattern %q with %%q]], %s)', ctx:libfunc('string.format'), schema.pattern, ctx:param(1)))
      ctx:stmt(        '  end')
    end
    ctx:stmt('end') -- if string
  end

  if schema.minimum or schema.maximum or schema.multipleOf then
    ctx:stmt(sformat('if %s == "number" then', datatype))

    if schema.minimum then
      local op = schema.exclusiveMinimum and '<=' or '<'
      local msg = schema.exclusiveMinimum and 'sctrictly greater' or 'greater'
      ctx:stmt(sformat('  if %s %s %s then', ctx:param(1), op, schema.minimum))
      ctx:stmt(sformat('    return false, %s("expected %%s to be %s than %s", %s)',
                       ctx:libfunc('string.format'), msg, schema.minimum, ctx:param(1)))
      ctx:stmt(        '  end')
    end

    if schema.maximum then
      local op = schema.exclusiveMaximum and '>=' or '>'
      local msg = schema.exclusiveMaximum and 'sctrictly smaller' or 'smaller'
      ctx:stmt(sformat('  if %s %s %s then', ctx:param(1), op, schema.maximum))
      ctx:stmt(sformat('    return false, %s("expected %%s to be %s than %s", %s)',
                       ctx:libfunc('string.format'), msg, schema.maximum, ctx:param(1)))
      ctx:stmt(        '  end')
    end

    local mof = schema.multipleOf
    if mof then
      -- TODO: optimize integer case
      if mmodf(mof) == mof then
        -- integer multipleOf: modulo is enough
        ctx:stmt(sformat('  if %s %% %d ~= 0 then', ctx:param(1), mof))
      else
          -- float multipleOf: it's a bit more hacky and slow
        ctx:stmt(sformat('  local quotient = %s / %s', ctx:param(1), mof))
        ctx:stmt(sformat('  if %s(quotient) ~= quotient then', ctx:libfunc('math.modf')))
      end
      ctx:stmt(sformat(  '    return false, %s("expected %%s to be a multiple of %s", %s)',
                       ctx:libfunc('string.format'), mof, ctx:param(1)))
      ctx:stmt(          '  end')
    end
    ctx:stmt('end') -- if number
  end

  -- enum values
  -- TODO: for big sets of hashable values (> 16 or so), it might be intersing to create a
  --       table beforehand
  if schema.enum then
    ctx:stmt('if not (')
    local lasti = #schema.enum
    for i, val in ipairs(schema.enum) do
      local tval = type(val)
      local op = i == lasti and '' or ' or'

      if tval == 'number' or tval == 'boolean' then
        ctx:stmt(sformat('  %s == %s', ctx:param(1), val), op)
      elseif tval == 'string' then
        ctx:stmt(sformat('  %s == %q', ctx:param(1), val), op)
      elseif tval == 'table' then
        ctx:stmt(sformat('  %s(%s, %s)', ctx:libfunc('lib.deepeq'), ctx:param(1), ctx:uservalue(val)), op)
      else
        error('unsupported enum type: ' .. tval) -- TODO: null
      end
    end
    ctx:stmt(') then')
    ctx:stmt('  return false, "matches non of the enum values"')
    ctx:stmt('end')
  end

  -- compound schemas
  -- (very naive implementation for now, can be optimized a lot)
  if schema.allOf then
    for i, subschema in ipairs(schema.allOf) do
      local validator = ctx:validator({ 'allOf', tostring(i-1) }, subschema)
      ctx:stmt(        'do')
      ctx:stmt(sformat('  local ok, err = %s(%s)', validator, ctx:param(1)))
      ctx:stmt(sformat('  if not ok then'))
      ctx:stmt(sformat('    return false, "allOf %d failed: " .. err', i))
      ctx:stmt(        '  end')
      ctx:stmt(        'end')
    end
  end

  if schema.anyOf then
    local lasti = #schema.anyOf
    ctx:stmt('if not (')
    for i, subschema in ipairs(schema.anyOf) do
      local op = i == lasti and '' or ' or'
      local validator = ctx:validator({ 'anyOf', tostring(i-1) }, subschema)
      ctx:stmt(sformat('  %s(%s)', validator, ctx:param(1)), op)
    end
    ctx:stmt(') then')
    ctx:stmt('  return false, "object matches none of the alternatives"')
    ctx:stmt('end')
  end

  if schema.oneOf then
    ctx:stmt('do')
    ctx:stmt('  local matched')
    for i, subschema in ipairs(schema.oneOf) do
      local validator = ctx:validator({ 'oneOf', tostring(i-1) }, subschema)
      ctx:stmt(sformat('  if %s(%s) then', validator, ctx:param(1)))
      ctx:stmt(        '    if matched then')
      ctx:stmt(sformat('      return false, %s("value sould match only one schema, but matches both schemas %%d and %%d", matched, %d)',
                       ctx:libfunc('string.format'), i))
      ctx:stmt(        '    end')
      ctx:stmt(        '    matched = ', tostring(i))
      ctx:stmt(        '  end')
    end
    ctx:stmt('  if not matched then')
    ctx:stmt('    return false, "value sould match only one schema, but matches none"')
    ctx:stmt('  end')
    ctx:stmt('end')
  end

  if schema['not'] then
    local validator = ctx:validator({ 'not' }, schema['not'])
    ctx:stmt(sformat('if %s(%s) then', validator, ctx:param(1)))
    ctx:stmt(        '  return false, "value wasn\'t supposed to match schema"')
    ctx:stmt(        'end')
  end

  ctx:stmt('return true')
  return ctx
end

local function generate_main_validator_ctx(schema, options)
  local ctx = codectx(schema, options or {})
  -- the root function takes two parameters:
  --  * the validation library (auxiliary function used during validation)
  --  * the custom callbacks (used to customize various aspects of validation
  --    or for dependency injection)
  ctx:preface('local uservalues, lib, custom = ...')
  ctx:stmt('return ', ctx:validator(nil, schema))
  return ctx
end

return {
  generate_validator = function(schema, custom)
    local customlib = {
      null = custom and custom.null or default_null,
      match_pattern = custom and custom.match_pattern or string.find
    }
    local name = custom and custom.name
    return generate_main_validator_ctx(schema, custom):as_func(name, validatorlib, customlib)
  end,
  -- debug only
  generate_validator_code = function(schema, custom)
    return generate_main_validator_ctx(schema, custom):as_string()
  end,
}
