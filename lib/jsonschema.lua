local store = require 'jsonschema.store'
local loadstring = loadstring
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local unpack = unpack or table.unpack
local sformat = string.format
local mmax, mmodf = math.max, math.modf
local DEBUG = os and os.getenv and os.getenv('DEBUG') == '1'
local tab_concat = table.concat
local tab_insert = table.insert
local string = string
local str_byte = string.byte

-- default null token
local default_null = nil
local json_encode
do
  local ok, cjson = pcall(require, 'cjson.safe')
  if ok then
    default_null = cjson.null
    json_encode = cjson.encode
  end
end

local tab_nkeys = nil
do
  local ok, nkeys = pcall(require, 'table.nkeys')
  if ok then
    tab_nkeys = nkeys
  else
    tab_nkeys = function(t)
      local count = 0
      for _, _ in pairs(t) do
        count = count + 1
      end
      return count
    end
  end
end

local match_pattern
local rex_find
if ngx then
  local function re_find(s, p)
    return ngx.re.find(s, p, "jo")
  end
  match_pattern = re_find
else
  match_pattern = function (s, p)
    if not rex_find then
      local ok, rex = pcall(require, "rex_pcre")
      if not ok then
        error("depends on lrexlib-pcre, please install it first: " .. rex)
      end

      rex_find = rex.find
    end
    return rex_find(s, p)
  end
end

local parse_ipv4
local parse_ipv6
if ngx then
  local ffi = require "ffi"
  local new_tab = require "table.new"
  local inet = ffi.new("unsigned int [1]")
  local inets = ffi.new("unsigned int [4]")
  local AF_INET     = 2
  local AF_INET6    = 10
  if ffi.os == "OSX" then
    AF_INET6 = 30
  end

  ffi.cdef[[
    int inet_pton(int af, const char * restrict src, void * restrict dst);
  ]]

  function parse_ipv4(ip)
    if not ip then
      return false
    end

    return ffi.C.inet_pton(AF_INET, ip, inet) == 1
  end

  function parse_ipv6(ip)
    if not ip then
      return false
    end

    return ffi.C.inet_pton(AF_INET6, ip, inets) == 1
  end
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
  for i = 1, nres do
    names[i] = sformat('var_%d_%d', self._idx, nloc + i)
  end

  self:stmt(sformat('local %s = ', tab_concat(names, ', ')), init or 'nil')
  self._nloc = nloc + nres
  return unpack(names)
end

function codectx_mt:localvartab(init, nres)
    local names = {}
    local nloc = self._nloc
    nres = nres or 1
    for i = 1, nres do
      names[i] = sformat('locals.var_%d_%d', self._idx, nloc + i)
    end

    self:stmt(sformat('%s = ', tab_concat(names, ', ')), init or 'nil')
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
    var = root:localvartab('nil')
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
local function insert_code(chunk, code_table)
  if chunk and chunk ~= '' then
    tab_insert(code_table, chunk)
  end
end

function codectx_mt:_generate(code_table)
  local indent = ''
  if self._root == self then
    for _, stmt in ipairs(self._preface) do
      insert_code(indent, code_table)
      if getmetatable(stmt) == codectx_mt then
        stmt:_generate(code_table)
      else
        insert_code(stmt, code_table)
      end
    end
  else
    insert_code('function(', code_table)
    for i=1, self._nparams do
      insert_code('p_' .. i, code_table)
      if i ~= self._nparams then insert_code(', ', code_table) end
    end
    insert_code(')\n', code_table)
    indent = string.rep('  ', self._idx)
  end

  for _, stmt in ipairs(self._body) do
    insert_code(indent, code_table)
    if getmetatable(stmt) == codectx_mt then
      stmt:_generate(code_table)
    else
      insert_code(stmt, code_table)
    end
  end

  if self._root ~= self then
    insert_code('end', code_table)
  end
end

function codectx_mt:_get_loader()
  self._code_table = {}
  self:_generate(self._code_table)
  return self._code_table
end

function codectx_mt:as_string()
  self:_get_loader()
  return tab_concat(self._code_table)
end

local function split(s, sep)
    local res = {}

    if #s > 0 then
       local n, start = 1, 1
       local first, last = s:find(sep, start, true)
       while first do
          res[n] = s:sub(start, first - 1)
          n = n + 1
          start = last + 1
          first,last = s:find(sep, start, true)
       end

       res[n] = s:sub(start)
    end

    return res
end

function codectx_mt:as_func(name, ...)
  self:_get_loader()
  local loader, err = loadstring(tab_concat(self._code_table, ""), 'jsonschema:' .. (name or 'anonymous'))
  if DEBUG then
    print('------------------------------')
    print('generated code:')
    -- OpenResty limits its log size under 4096 (including the prefix/suffix),
    -- so we use a lower limit here.
    -- This should not make any difference for non-OpenResty users.
    local max_len = 3900
    local current_len = 0
    local buf = {}
    local lines = split(self:as_string(), "\n")
    for i, line in ipairs(lines) do
        local s = sformat('\n%04d: %s', i, line)
        if #s + current_len > max_len then
            print(table.concat(buf))
            buf = {}
            current_len = 0
        end
        table.insert(buf, s)
        current_len = current_len + #s
    end
    print(table.concat(buf))
    print('------------------------------')
  end

  if loader then
    local validator
    validator, err = loader(self._uservalues, ...)
    if validator then return validator end
  end

  -- something went really wrong
  if DEBUG then
    print('FAILED to generate validator: ', err)
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
    _code_table = {},
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
    if tab_nkeys(t) == 0 then
      return 1 -- empty table
    end

    return 0 -- pure hash
  end

  -- not empty, check if the number of items is the same as the length
  if tab_nkeys(t) == length then
    return 2 -- array
  end

  return 0 -- mixed array/object
end


local accept_range = {
  {lo = 0x80, hi = 0xBF},
  {lo = 0xA0, hi = 0xBF},
  {lo = 0x80, hi = 0x9F},
  {lo = 0x90, hi = 0xBF},
  {lo = 0x80, hi = 0x8F}
}

function validatorlib.utf8_len(str)
  local i, n, c = 1, #str, 0
  local first, byte, left_size, range_idx

  while i <= n do
    first = str_byte(str, i)
    if first >= 0x80 and first <= 0xF4 then
      left_size = 0
      range_idx = 1
      if first >= 0xC2 and first <= 0xDF then --2 bytes
        left_size = 1
      elseif first >= 0xE0 and first <= 0xEF then --3 bytes
        left_size = 2
        if first == 0xE0 then
          range_idx = 2
        elseif first == 0xED then
          range_idx = 3
        end
      elseif first >= 0xF0 and first <= 0xF4 then --4 bytes
        left_size = 3
        if first == 0xF0 then
          range_idx = 4
        elseif first == 0xF4 then
          range_idx = 5
        end
      end

      if i + left_size > n then --invalid
        left_size = 0
      end

      for j = 1, left_size do
        byte = str_byte(str, i + j)
        if byte < accept_range[range_idx].lo or byte > accept_range[range_idx].hi then --invalid
          left_size = 0
          break
        end
        range_idx = 1
      end
      i = i + left_size
    end
    i = i + 1
    c = c + 1
  end

  return c
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


local function unique_item_in_array(arr)
    local existed_items, tab_items, n_tab_items = {}, {}, 0
    for i, val in ipairs(arr) do
        if type(val) == 'table' then
            n_tab_items = n_tab_items + 1
            tab_items[n_tab_items] = val
        else
            if existed_items[val] then
              return false, existed_items[val], i
            end
        end
        existed_items[val] = i
    end
    --check for table items
    if n_tab_items > 1 then
        for i = 1, n_tab_items - 1 do
            for j = i + 1, n_tab_items do
                if deepeq(tab_items[i], tab_items[j]) then
                    return false, existed_items[tab_items[i]], existed_items[tab_items[j]]
                end
            end
        end
    end
    return true
end
validatorlib.unique_item_in_array = unique_item_in_array


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
    return sformat(' ((%s == "number" or (%s == "cdata" and tonumber(%s) ~= nil)) and %s %% 1.0 == 0.0) ',
      datatype, datatype, ctx:param(1), ctx:param(1))
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

local function str_rep_quote(m)
  local ch1 = m:sub(1, 1)
  local ch2 = m:sub(2, 2)
  if ch1 == "\\" then
    return ch2
  end

  return ch1 .. "\\" .. ch2
end

local function str_filter(s)
  s = string.format("%q", s)
  -- print(s)
  if s:find("\\\n", 1, true) then
      s = string.gsub(s, "\\\n", "\\n")
  end

  if s:find("'", 1, true) then
    s = string.gsub(s, ".?'", str_rep_quote)
  end
  return s
end

local function to_lua_code(var)
  if type(var) == "string" then
    return sformat("%q", var)
  end

  if type(var) ~= "table" then
    return var
  end

  local code = "{"
  for k, v in pairs(var) do
    code = code .. string.format("[%s] = %s,", to_lua_code(k), to_lua_code(v))
  end
  return code .. "}"
end

local function addRangeCheck(ctx, op, reference, msg)
  ctx:stmt(sformat('  if %s %s %s then', ctx:param(1), op, reference))
  ctx:stmt(sformat('    return false, %s("expected %%s to be %s %s", %s)',
                    ctx:libfunc('string.format'), msg, reference, ctx:param(1)))
  ctx:stmt(        '  end')
end

generate_validator = function(ctx, schema)
  -- get type informations as they will be necessary anyway
  local datatype = ctx:localvartab(sformat('%s(%s)',
    ctx:libfunc('type'), ctx:param(1)))
  local datakind = ctx:localvartab(sformat('%s == "table" and %s(%s)',
    datatype, ctx:libfunc('lib.tablekind'), ctx:param(1)))

  if type(schema) == "table" and schema._org_val ~= nil then
    schema = schema._org_val
  end

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
      ctx:stmt(sformat(  '    local propvalue = %s[%s]', ctx:param(1), str_filter(prop)))
      ctx:stmt(          '    if propvalue ~= nil then')
      ctx:stmt(sformat(  '      local ok, err = %s(propvalue)', propvalidator))
      ctx:stmt(          '      if not ok then')
      ctx:stmt(sformat(  "        return false, 'property %s validation failed: ' .. err", str_filter(prop)))
      ctx:stmt(          '      end')

      if dependencies[prop] then
        local d = dependencies[prop]
        if #d > 0 then
          -- dependency is a list of properties
          for _, depprop in ipairs(d) do
            ctx:stmt(sformat('      if %s[ %q ] == nil then', ctx:param(1), depprop))
            ctx:stmt(sformat("        return false, 'property %q is required when %s is set'", depprop, str_filter(prop)))
            ctx:stmt(        '      end')
          end
        else
          -- dependency is a schema
          local depvalidator = ctx:validator({ 'dependencies', prop }, d)
          -- ok and err are already defined in this block
          ctx:stmt(sformat('      ok, err = %s(%s)', depvalidator, ctx:param(1)))
          ctx:stmt(        '      if not ok then')
          ctx:stmt(sformat("        return false, 'failed to validate dependent schema for %s: ' .. err", str_filter(prop)))
          ctx:stmt(        '      end')
        end
      end

      if required[prop] then
        ctx:stmt(        '    else')
        ctx:stmt(sformat("      return false, 'property %s is required'", str_filter(prop)))
        required[prop] = nil
      end
      ctx:stmt(          '    end') -- if prop

      if type(subschema) == "table" and subschema.default ~= nil and
         (type(subschema.default) == "number" or
          type(subschema.default) == "string" or
          type(subschema.default) == "boolean" or
          type(subschema.default) == "table") then
        local default = to_lua_code(subschema.default)
        ctx:stmt(        '    if propvalue == nil then')
        ctx:stmt(sformat('      %s[%s] = %s', ctx:param(1), str_filter(prop), default))
        ctx:stmt(        '    end')
      end

      ctx:stmt(          '  end') -- do
    end

    -- check the rest of required fields
    for prop, _ in pairs(required) do
      ctx:stmt(sformat('  if %s[%s] == nil then', ctx:param(1), str_filter(prop)))
      ctx:stmt(sformat("      return false, 'property %s is required'", str_filter(prop)))
      ctx:stmt(        '  end')
    end

    -- check the rest of dependencies
    for prop, d in pairs(dependencies) do
      if not properties[prop] then
        if type(d) == "table" and #d > 0 then
          -- dependencies are a list of properties
          for _, depprop in ipairs(d) do
            ctx:stmt(sformat('  if %s[ %s ] ~= nil and %s[%q] == nil then', ctx:param(1), str_filter(prop), ctx:param(1), depprop))
            ctx:stmt(sformat("    return false, 'property %s is required when %s is set'", str_filter(depprop), str_filter(prop)))
            ctx:stmt(        '  end')
          end
        else
          -- dependency is a schema
          local depvalidator = ctx:validator({ 'dependencies', prop }, d)
          ctx:stmt(sformat('  if %s[%s] ~= nil then', ctx:param(1), str_filter(prop)))
          ctx:stmt(sformat('    local ok, err = %s(%s)', depvalidator, ctx:param(1)))
          ctx:stmt(        '    if not ok then')
          ctx:stmt(sformat("      return false, 'failed to validate dependent schema for %s: ' .. err", str_filter(prop)))
          ctx:stmt(        '    end')
          ctx:stmt(        '  end')
        end
      end
    end

    -- patternProperties and additionalProperties
    local propset, addprop_validator -- all properties defined in the object
    if schema.additionalProperties ~= nil and schema.additionalProperties ~= true then
      -- TODO: can be optimized with a static table expression
      propset = ctx._root:localvartab('{}')
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

    if schema.required and #schema.required == 0 then
      -- return false if the input data is not empty
      ctx:stmt(sformat('if %s ~= 1 then', datakind))
      ctx:stmt(        '  return false, "the input data should be an empty table"')
      ctx:stmt(        'end')
    end
  end

  -- array checks
  if schema.items ~= nil or schema.minItems or schema.maxItems or schema.uniqueItems then
    if schema.items == true then
      ctx:stmt(        'do return true end')

    elseif schema.items == false then
      ctx:stmt(sformat('if %s == "table" and %s == 1 then', datatype, datakind))
      ctx:stmt(        '  return true')
      ctx:stmt(        'else')
      ctx:stmt(        '  return false, "expect false always"')
      ctx:stmt(        'end')
    end

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
        ctx:stmt(sformat('    return false, "expect array to have at most %s items"', schema.maxItems))
        ctx:stmt(        '  end')
      end
    end

    if type(schema.items) == "table" and #schema.items > 0 then
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

    if schema.uniqueItems then
      ctx:stmt(sformat('  local ok, item1, item2 = %s(%s)', ctx:libfunc('lib.unique_item_in_array'), ctx:param(1)))
      ctx:stmt(sformat('  if not ok then', ctx:libfunc('lib.unique_item_in_array'), ctx:param(1)))
      ctx:stmt(sformat('    return false, %s("expected unique items but items %%d and %%d are equal", item1, item2)', ctx:libfunc('string.format')))
      ctx:stmt(        '  end')
    end
    ctx:stmt('end') -- if array
  end

  if schema.minLength or schema.maxLength or schema.pattern then
    ctx:stmt(sformat('if %s == "string" then', datatype))
    if schema.minLength then
      ctx:stmt(sformat('  local c = %s(%s)', ctx:libfunc('lib.utf8_len'), ctx:param(1)))
      ctx:stmt(sformat('  if c < %d then', schema.minLength))
      ctx:stmt(sformat('    return false, %s("string too short, expected at least %d, got ") ..c',
                       ctx:libfunc('string.format'), schema.minLength))
      ctx:stmt(        '  end')
    end
    if schema.maxLength then
      ctx:stmt(sformat('  local c = %s(%s)', ctx:libfunc('lib.utf8_len'), ctx:param(1)))
      ctx:stmt(sformat('  if c > %d then', schema.maxLength))
      ctx:stmt(sformat('    return false, %s("string too long, expected at most %d, got ") .. c',
                       ctx:libfunc('string.format'), schema.maxLength))
      ctx:stmt(        '  end')
    end
    if schema.pattern then
      ctx:stmt(sformat('  if not %s(%s, %q) then', ctx:libfunc('custom.match_pattern'), ctx:param(1), schema.pattern))
      ctx:stmt(sformat('    return false, %s([[failed to match pattern %q with %%q]], %s)', ctx:libfunc('string.format'), string.gsub(schema.pattern, "%%", "%%%%"), ctx:param(1)))
      ctx:stmt(        '  end')
    end
    ctx:stmt('end') -- if string
  end

  if schema.minimum or schema.maximum or schema.multipleOf or schema.exclusiveMinimum or schema.exclusiveMaximum then
    ctx:stmt(sformat('if %s == "number" then', datatype))

    if schema.minimum then
      addRangeCheck(ctx, '<', schema.minimum, 'at least')
    end
    if schema.exclusiveMinimum then
      addRangeCheck(ctx, '<=', schema.exclusiveMinimum, 'greater than')
    end
    if schema.maximum then
      addRangeCheck(ctx, '>', schema.maximum, 'at most')
    end
    if schema.exclusiveMaximum then
      addRangeCheck(ctx, '>=', schema.exclusiveMaximum, 'smaller than')
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
  -- TODO: for big sets of hashable values (> 16 or so), it might be interesting to create a
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
    ctx:stmt('  return false, "matches none of the enum values"')
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
    local requires = {}
    ctx:stmt('if not (')
    for i, subschema in ipairs(schema.anyOf) do
      local op = i == lasti and '' or ' or'
      local validator = ctx:validator({ 'anyOf', tostring(i-1) }, subschema)
      ctx:stmt(sformat('  %s(%s)', validator, ctx:param(1)), op)
      if json_encode and type(subschema) == "table" and subschema.required then
        local str = json_encode(subschema.required)
        if str then
          tab_insert(requires, str)
        end
      end
    end

    if #requires > 0 then
      requires = ' ": " .. ' .. sformat("%q", tab_concat(requires, " or "))
    else
      requires = ' ""'
    end

    ctx:stmt(') then')
    ctx:stmt('  return false, "object matches none of the required" .. ' .. requires)
    ctx:stmt('end')
  end

  if schema.oneOf then
    ctx:stmt('do')
    ctx:stmt('  local matched')
    for i, subschema in ipairs(schema.oneOf) do
      local validator = ctx:validator({ 'oneOf', tostring(i-1) }, subschema)
      ctx:stmt(sformat('  if %s(%s) then', validator, ctx:param(1)))
      ctx:stmt(        '    if matched then')
      ctx:stmt(sformat('      return false, %s("value should match only one schema, but matches both schemas %%d and %%d", matched, %d)',
                       ctx:libfunc('string.format'), i))
      ctx:stmt(        '    end')
      ctx:stmt(        '    matched = ', tostring(i))
      ctx:stmt(        '  end')
    end
    ctx:stmt('  if not matched then')
    ctx:stmt('    return false, "value should match only one schema, but matches none"')
    ctx:stmt('  end')
    ctx:stmt('end')
  end

  if schema['if'] then
    ctx:stmt(          'do')
    local validator = ctx:validator({ 'if' }, schema['if'])
    ctx:stmt(sformat(  '  local matched = %s(%s)', validator, ctx:param(1)))
    if schema['then'] then
      ctx:stmt(        '  if matched then')
      validator = ctx:validator({ 'then' }, schema['then'])
      ctx:stmt(sformat('    if not %s(%s) then', validator, ctx:param(1)))
      ctx:stmt(        '      return false, "then clause did not match"')
      ctx:stmt(        '    end')
      ctx:stmt(        '  end')
    end
    if schema['else'] then
      ctx:stmt(        '  if not matched then')
      validator = ctx:validator({ 'else' }, schema['else'])
      ctx:stmt(sformat('    if not %s(%s) then', validator, ctx:param(1)))
      ctx:stmt(        '      return false, "else clause did not match"')
      ctx:stmt(        '    end')
      ctx:stmt(        '  end')
    end
    ctx:stmt(          'end')
  end

  if schema['not'] then
    local validator = ctx:validator({ 'not' }, schema['not'])
    ctx:stmt(sformat('if %s(%s) then', validator, ctx:param(1)))
    ctx:stmt(        '  return false, "value wasn\'t supposed to match schema"')
    ctx:stmt(        'end')
  end

  if schema.propertyNames == true then
    ctx:stmt(        'do return true end')

  elseif schema.propertyNames == false then
    ctx:stmt(sformat('if %s == "table" and %s == 1 then', datatype, datakind))
    ctx:stmt(        '  return true')
    ctx:stmt(        'else')
    ctx:stmt(        '  return false, "expect false always"')
    ctx:stmt(        'end')
  end

  if schema.format == "email" then
    local reg = [[^([A-Za-z0-9_\-\.])+\@([A-Za-z0-9_\-\.])+\.([A-Za-z]{2,4})$]]
    ctx:stmt(sformat('if type(%s) == "string" and not %s(%s, [[%s]]) then', ctx:param(1), ctx:libfunc('custom.match_pattern'), ctx:param(1), reg))
    ctx:stmt(sformat('  return false, "expect valid email address but got: " .. %s', ctx:param(1)))
    ctx:stmt(        'end')
  end

  if schema.format == "ipv4" then
    local reg = [[^(((\d{1,2})|(1\d{2})|(2[0-4]\d)|(25[0-5]))\.){3}((\d{1,2})|(1\d{2})|(2[0-4]\d)|(25[0-5]))$]]
    if ngx then
      ctx:stmt(sformat('if type(%s) == "string" and not %s(%s) then', ctx:param(1), ctx:libfunc('custom.parse_ipv4'), ctx:param(1)))
    else
      ctx:stmt(sformat('if type(%s) == "string" and not %s(%s, [[%s]]) then', ctx:param(1), ctx:libfunc('custom.match_pattern'), ctx:param(1), reg))
    end
    ctx:stmt(sformat('  return false, "expect valid ipv4 address but got: " .. %s', ctx:param(1)))
    ctx:stmt(        'end')
  end

  if schema.format == "ipv6" then
    local reg = [[^\s*((([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))(%.+)?\s*$]]
    if ngx then
      ctx:stmt(sformat('if type(%s) == "string" and not %s(%s) then', ctx:param(1), ctx:libfunc('custom.parse_ipv6'), ctx:param(1)))
    else
      ctx:stmt(sformat('if type(%s) == "string" and not %s(%s, [[%s]]) then', ctx:param(1), ctx:libfunc('custom.match_pattern'), ctx:param(1), reg))
    end
    ctx:stmt(sformat('  return false, "expect valid ipv6 address but got: " .. %s', ctx:param(1)))
    ctx:stmt(        'end')
  end

  if schema.format == "hostname" then
    local reg = [[^[a-zA-Z0-9\-\.]+$]]
    ctx:stmt(sformat('if type(%s) == "string" and not %s(%s, [[%s]]) then', ctx:param(1), ctx:libfunc('custom.match_pattern'), ctx:param(1), reg))
    ctx:stmt(sformat('  return false, "expect valid ipv4 address but got: " .. %s', ctx:param(1)))
    ctx:stmt(        'end')
  end

  if schema.const ~= nil then
    ctx:stmt(sformat('if not %s(%s, %s) then', ctx:libfunc('lib.deepeq'), ctx:param(1), ctx:uservalue(schema.const)))
    ctx:stmt(sformat('  return false, "failed to check const value"'))
    ctx:stmt(        'end')
  end

  if schema.contains == true then
    ctx:stmt(sformat('if %s == "table" and %s == 2 then', datatype, datakind))
    ctx:stmt(        '  return true')
    ctx:stmt(        'else')
    ctx:stmt(        '  return false, "check contains: expect array table"')
    ctx:stmt(        'end')

  elseif schema.contains == false then
    ctx:stmt(sformat('if %s ~= "table" then', datatype))
    ctx:stmt(        '  return true')
    ctx:stmt(        'else')
    ctx:stmt(        '  return false, "check contains: expect table"')
    ctx:stmt(        'end')

  elseif schema.contains ~= nil then
    ctx:stmt(sformat('if %s == "table" and %s == 1 then', datatype, datakind))
    ctx:stmt(        '  return false, "check contains: empty array is invalid"')
    ctx:stmt(        'end')

    local validator = ctx:validator({ 'contains' }, schema.contains)
    local for_val = ctx._root:localvar('val')
    local count = ctx._root:localvar('0')
    ctx:stmt(sformat('local %s = 0', count))
    ctx:stmt(sformat('for _, %s in ipairs(%s) do', for_val, ctx:param(1)))
    ctx:stmt(sformat('  if not %s(%s) then', validator, for_val))
    ctx:stmt(sformat('    %s = %s + 1', count, count))
    ctx:stmt(        '  end')
    ctx:stmt(        'end')
    ctx:stmt(sformat('if #%s > 0 and %s == #%s then ', ctx:param(1), count, ctx:param(1)))
    ctx:stmt(        '  return false, "failed to check contains"')
    ctx:stmt(        'end')
  end

  ctx:stmt('return true')
  return ctx
end

local function generate_main_validator_ctx(schema, options)
  if type(schema) ~= "table" then
    schema = {_org_val = schema}
  end
  local ctx = codectx(schema, options or {})
  -- the root function takes two parameters:
  --  * the validation library (auxiliary function used during validation)
  --  * the custom callbacks (used to customize various aspects of validation
  --    or for dependency injection)
  ctx:preface('local uservalues, lib, custom = ...')
  ctx:preface('local locals = {}')
  ctx:stmt('return ', ctx:validator(nil, schema))
  return ctx
end

return {
  generate_validator = function(schema, custom)
    local customlib = {
      null = custom and custom.null or default_null,
      match_pattern = custom and custom.match_pattern or match_pattern,
      parse_ipv4 = custom and custom.parse_ipv4 or parse_ipv4,
      parse_ipv6 = custom and custom.parse_ipv6 or parse_ipv6
    }
    local name = custom and custom.name
    local has_original_id
    if type(schema) == "table" and schema.id then
      has_original_id = true
    end
    local ctx = generate_main_validator_ctx(schema, custom):as_func(name, validatorlib, customlib)
    if type(schema) == "table" and not has_original_id then
      schema.id = nil
    end
    return ctx
  end,
  -- debug only
  generate_validator_code = function(schema, custom)
    return generate_main_validator_ctx(schema, custom):as_string()
  end,
}
