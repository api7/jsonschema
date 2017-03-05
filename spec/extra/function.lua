return {
  {
    description = "function type",
    schema = { type = "function" },
    tests = {
      {
        description = "Lua function",
        data = function() end,
        valid = true
      },
      {
        description = "C function",
        data = print,
        valid = true
      },
      {
        description = "table",
        data = {},
        valid = false
      },
    }
  }
}
