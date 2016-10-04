
local cjson = require 'cjson' -- TODO: make this configurable

local sformat = string.format
local tconcat = table.concat
local mmodf, mfmod, mmin = math.modf, math.fmod, math.min
local null = cjson.null

-- TODO: check that keys for json objects are only strings
-- TODO: test invalid schemas

-- TODO: this function is critical for performance, optimize it
-- Returns:
--  0 for objects
--  1 for empty object/table (these two are indistinguishable in Lua)
--  2 for arrays
local function table_kind(t)
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

local type_map = {
  integer = function(d) return type(d) == 'number' and mfmod(d, 1.0) == 0.0 end,
  number  = function(d) return type(d) == 'number' end,
  string  = function(d) return type(d) == 'string' end,
  object  = function(d, tk) return type(d) == 'table' and tk <= 1 end,
  array   = function(d, tk) return type(d) == 'table' and tk >= 1 end,
  boolean = function(d) return type(d) == 'boolean' end,
  null    = function(d) return d == null end, -- TODO: support nil too?
}

-- pattern matching function, default to the Lua pattern matching engine, lacks
-- many features compared to ECMA-262 specification. The user can provide a
-- richer pattern matching engine if available (ngx.re, libpcre, ...)
local match_pattern = string.find
-- TODO: setter

-- used for unique items in arrays (not fast at all)
-- from: http://stackoverflow.com/questions/25922437
-- If we consider only the JSON case, this function could be simplified:
-- no loops, keys are only strings. But this library might also be used in
-- other cases.
function table_eq(table1, table2)
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
               if table_eq(k1, tk) and recurse(v1, t2[tk]) then
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


local function validate(data, schema)
  -- check type
  local tt = type(schema.type)
  local tk = type(data) == 'table' and table_kind(data)
  if tt == 'table' then
    local valid = false
    for _, t in ipairs(schema.type) do
      if type_map[t](data, tk) then
        valid = true
        break
      end
    end
    if not valid then
      return false, sformat('expected one of %s, got %s', tconcat(schema.type), type(d))
    end
  elseif tt == 'string' then
    if not type_map[schema.type](data, tk) then
      return false, sformat('expected %s, got %s', schema.type, type(d))
    end
  elseif tt ~= 'nil' then
    -- TODO: check invalid schemas (validate schema itself?)
    error('invalid "type": got ' .. tt)
  end

  -- check properties, this differs from the spec as empty arrays are
  -- considered as object. Because, YES, JSON schema actually ignore the
  -- properties if the data is not as object... This is how stupid this format
  -- is!
  if type(data) == 'table' and tk <= 1 then
    if schema.properties then
      for prop, subschema in pairs(schema.properties) do
        local subdata = data[prop]
        if subdata ~= nil then
          local ok, err = validate(data[prop], subschema)
          if not ok then
            return false, sformat('failed to validate %q: %s', prop, err)
          end
        end
      end
    end

    -- required properties
    if schema.required then
      for _, prop in ipairs(schema.required) do
        if data[prop] == nil then
          return false, sformat('property %q is required', prop)
        end
      end
    end

    local matched_props = nil
    if schema.patternProperties then
      matched_props = {}
      for patt, patt_schema in pairs(schema.patternProperties) do
        for prop, prop_data in pairs(data) do
          if match_pattern(prop, patt) then
            local ok, err = validate(prop_data, patt_schema)
            if ok then
              matched_props[prop] = true
            else
              return false, sformat(
                "property %q doesn't validate against pattern %q: %s",
                prop, patt, err)
            end -- if validate
          end -- if match
        end -- for data
      end -- for patternProperties
    end -- if patternProperties

    if schema.additionalProperties == false then
      for prop, _ in pairs(data) do
        if schema.properties[prop] == nil and
           (matched_props == nil or matched_props[prop] == nil)
        then
          return false, sformat(
            "additional properties forbidden, found %q", prop)
        end
      end
    elseif type(schema.additionalProperties) == 'table' then
      local properties = schema.properties or {}
      for prop, pdata in pairs(data) do
        if properties[prop] == nil and
           (matched_props == nil or matched_props[prop] == nil)
        then
          local ok, err = validate(pdata, schema.additionalProperties) 
          if not ok then
            return false, sformat(
              "failed to validate additional property %q: %s", prop, err)
          end -- if validate
        end -- if prop
      end -- for additionalProperties
    end -- if additionalProperties

    local minprop, maxprop = schema.minProperties, schema.maxProperties
    if minprop or maxprop then
      local nprop = 0 -- TODO: opportunistically count properties before
      for prop, pdata in pairs(data) do
        nprop = nprop + 1
      end

      if minprop and nprop < minprop then
        return false, sformat('expect object to have at least %s properties',
          minprop)
      end

      if maxprop and nprop > maxprop then
        return false, sformat('expect object to have at most %s properties',
          maxprop)
      end
    end
  end -- if object

  if type(data) == 'table' and tk >= 1 then
    local items = schema.items
    if items then
      if #items > 0 then -- array of schema
        -- From the section 5.1.3.2, missing an array with missing items is
        -- still valid, because... Well because!
        for i=1, mmin(#data, #items) do
          if data[i] ~= nil then
            local ok, err = validate(data[i], items[i])
            if not ok then
              return false, sformat('falied to validate item %s: %s', i, err)
            end
          end
        end
        
        local ai = schema.additionalItems
        local tai = type(ai)
        if tai == 'boolean' then
          if ai == false and #data > #items then
            return false, sformat('unexpected extra items: expected %d, got %d',
              #data, #items)
          end
        elseif tai == 'table' then
          for i=#items + 1, #data do
            local ok, err = validate(data[i], ai)
            if not ok then
              return false, sformat('extra item %d validation failed: %s',
                i, err)
            end
          end
        end
      else -- uniform schema for all items
        for i, idata in ipairs(data) do
          local ok, err = validate(idata, items)
          if not ok then
            return false, sformat('failed to validate item %d: %s', i, err)
          end -- if ok
        end -- for data
      end -- if #items
    end -- if items

    if schema.minItems then
      if #data < schema.minItems then
        return false, sformat('expected at least %d items, got %d',
          schema.minItems, #data)
      end
    end

    if schema.maxItems then
      if #data > schema.maxItems then
        return false, sformat('expected at most %d items, got %d',
          schema.maxItems, #data)
      end
    end

    if schema.uniqueItems then
      local simple_items = {}
      for i, item in ipairs(data) do
        if simple_items[item] then
          return false, sformat(
            'item %d should be unique, also present at index %d',
            i, simple_items[item])
        elseif type(item) == 'table' then
          for j=1, i-1 do
            if type(data[j]) == 'table' and table_eq(item, data[j]) then
              return false, sformat(
                'item %d should be unique, also present at index %d', i, j)
            end
          end
        end
        simple_items[item] = i
      end
    end
  end -- if array

  if type(data) == "string" then
    if schema.minLength and #data < schema.minLength then
      return false, sformat("string too short, expected at least %d, got %d",
        schema.minLength, #data)
    end
    if schema.maxLength and #data > schema.maxLength then
      return false, sformat("string too long, expected at most %d, got %d",
        schema.maxLength, #data)
    end
    if schema.pattern and not match_pattern(data, schema.pattern) then
      return false, sformat('expected %q to match pattern %q',
        data, schema.pattern)
    end
  end

  if type(data) == 'number' then
    if schema.multipleOf then -- TODO: optimize integer cases
      local quotient = data / schema.multipleOf
      if mmodf(quotient) ~= quotient then
        return false, sformat('expected %f to be a multiple of %f',
          data, schema.multipleOf)
      end
    end

    if schema.minimum then
      if data < schema.minimum then
        return false, sformat('expected %f to be greater than %f',
          data, schema.minimum)
      elseif schema.exclusiveMinimum and data == schema.minimum then
        return false, sformat('expected %f to be strictly greater than %f',
          data, schema.minimum)
      end 
    end

    if schema.maximum then
      if data > schema.maximum then
        return false, sformat('expected %f to be smaller than %f',
          data, schema.maximum)
      elseif schema.exclusiveMaximum and data == schema.maximum then
        return false, sformat('expected %f to be strictly smaller than %f',
          data, schema.maximum)
      end 
    end
  end

  return true
end

local function generate_validator(schema)
  return function(data)
    return validate(data, schema)
  end
end

return {
  generate_validator = generate_validator,
}
