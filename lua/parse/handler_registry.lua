local M = {}
local config = require("parse.config")
local legacy = require("parse.handlers")

local active = nil
local custom = {}
local disabled = {}
local custom_order = {}

local function has_custom(name)
  return type(custom[name]) == "table" and type(custom[name].parse) == "function"
end

local function builtin_names()
  return legacy.names(false)
end

local function is_builtin(name)
  for _, candidate in ipairs(builtin_names()) do
    if candidate == name then
      return true
    end
  end
  return false
end

local function remember_custom(name)
  for _, existing in ipairs(custom_order) do
    if existing == name then
      return
    end
  end
  table.insert(custom_order, name)
end

local function normalize_definition(def)
  if type(def) == "function" then
    return { parse = def }
  end
  if type(def) ~= "table" then
    return nil
  end
  local copy = vim.deepcopy(def)
  if copy.run and not copy.parse then
    copy.parse = copy.run
  end
  return copy
end

function M.register(name, def)
  if type(name) ~= "string" or name == "" then
    return nil, "handler name must be a non-empty string"
  end
  local normalized = normalize_definition(def)
  if not normalized or type(normalized.parse) ~= "function" then
    return nil, "handler must provide parse(data, done)"
  end
  custom[name] = normalized
  disabled[name] = nil
  remember_custom(name)
  return true
end

function M.unregister(name)
  custom[name] = nil
  for i = #custom_order, 1, -1 do
    if custom_order[i] == name then
      table.remove(custom_order, i)
    end
  end
end

function M.disable(name)
  disabled[name] = true
  if active == name then
    active = nil
  end
end

function M.get(name)
  return custom[name]
end

function M.template(name)
  local def = custom[name]
  if def and def.template then
    return def.template
  end
  return name == "usaco" and "usaco" or "cf"
end

local function run_builtin(name, data, done)
  local ok, err = legacy.set(name)
  if not ok then
    done(nil, err)
    return
  end
  legacy.route(data, function(spec, route_err)
    legacy.set("manual")
    done(spec, route_err)
  end)
end

local function run_handler(name, data, done)
  if disabled[name] then
    done(nil, "handler is disabled: " .. tostring(name))
    return
  end
  if has_custom(name) then
    custom[name].parse(data, done)
    return
  end
  if is_builtin(name) then
    run_builtin(name, data, done)
    return
  end
  done(nil, "unknown parser: " .. tostring(name))
end

local function custom_detect(data)
  local candidates = {}
  for name, def in pairs(custom) do
    if not disabled[name] and type(def.detect) == "function" then
      table.insert(candidates, { name = name, def = def })
    end
  end
  table.sort(candidates, function(a, b)
    local ap = tonumber(a.def.priority) or 0
    local bp = tonumber(b.def.priority) or 0
    if ap == bp then
      return a.name < b.name
    end
    return ap > bp
  end)

  for _, candidate in ipairs(candidates) do
    local ok, matched = pcall(candidate.def.detect, data)
    if ok and matched then
      return candidate.name
    end
  end
  return nil
end

local function builtin_detect(data)
  local url = (data.url or ""):lower()
  local source = (data.source or ""):lower()
  local group = (data.group or ""):lower()
  local checks = {
    { "oly", url:find("oj.uz", 1, true) or source:find("oj.uz", 1, true) },
    { "cf", url:find("codeforces.com", 1, true) or group:find("codeforces", 1, true) },
    { "atcoder", url:find("atcoder.jp", 1, true) or group:find("atcoder", 1, true) },
    { "qoj", url:find("qoj.ac", 1, true) or group:match("^qoj") },
    { "uva", url:find("onlinejudge.org", 1, true) or url:find("uva.onlinejudge.org", 1, true) },
    { "codechef", url:find("codechef.com", 1, true) or group:find("codechef", 1, true) },
    { "cses", url:find("cses.fi", 1, true) or group:find("cses", 1, true) },
    { "usaco", url:find("usaco.org", 1, true) or group:find("usaco", 1, true) },
  }
  for _, item in ipairs(checks) do
    if item[2] and not disabled[item[1]] then
      return item[1]
    end
  end
  return nil
end

local function choose_parser(title, done)
  vim.ui.select(M.names(false), {
    prompt = title or "Parser: ",
    format_item = function(name)
      return M.label(name)
    end,
  }, function(choice)
    if not choice then
      done(nil, "cancelled")
      return
    end
    done(choice)
  end)
end

function M.names(include_modes)
  local result = {}
  local seen = {}
  for _, name in ipairs(builtin_names()) do
    if not disabled[name] then
      table.insert(result, name)
      seen[name] = true
    end
  end
  for _, name in ipairs(custom_order) do
    if not disabled[name] and not seen[name] then
      table.insert(result, name)
      seen[name] = true
    end
  end
  if include_modes then
    table.insert(result, 1, "manual")
    table.insert(result, 2, "auto")
  end
  return result
end

function M.label(name)
  if name == nil or name == "manual" then
    return "manual"
  end
  if name == "auto" then
    return "auto"
  end
  local def = custom[name]
  if def and def.label then
    return def.label
  end
  return legacy.label(name)
end

function M.setup(initial)
  active = nil
  custom = {}
  disabled = {}
  custom_order = {}

  for name, def in pairs(config.get().handlers or {}) do
    if def == false then
      disabled[name] = true
    else
      local ok, err = M.register(name, def)
      if not ok then
        error("parse.nvim: invalid handler '" .. tostring(name) .. "': " .. tostring(err))
      end
    end
  end

  local ok, err = M.set(initial)
  if not ok then
    error("parse.nvim: " .. tostring(err))
  end
end

function M.current()
  return active
end

function M.set(name)
  if name == nil or name == "" or name == "manual" then
    active = nil
    return true
  end
  if name == "auto" then
    active = "auto"
    return true
  end
  if disabled[name] then
    return nil, "handler is disabled: " .. tostring(name)
  end
  if has_custom(name) or is_builtin(name) then
    active = name
    return true
  end
  return nil, "unknown parser: " .. tostring(name)
end

function M.pick_and_set(done)
  choose_parser("Use parser: ", function(choice, err)
    if not choice then
      if done then
        done(nil, err)
      end
      return
    end
    active = choice
    if done then
      done(choice)
    end
  end)
end

function M.route(data, done)
  if active == "auto" then
    local detected = custom_detect(data) or builtin_detect(data)
    if detected then
      run_handler(detected, data, done)
      return
    end
    choose_parser("Auto detection failed; use parser: ", function(choice, err)
      if not choice then
        done(nil, err)
        return
      end
      run_handler(choice, data, done)
    end)
    return
  end

  if active then
    run_handler(active, data, done)
    return
  end

  choose_parser("Parse with: ", function(choice, err)
    if not choice then
      done(nil, err)
      return
    end
    run_handler(choice, data, done)
  end)
end

return M
