local M = {}
local config = require("parse.config")
local util = require("parse.util")

local active = nil

local order = {
  "cf",
  "atcoder",
  "qoj",
  "codechef",
  "cses",
  "usaco",
  "uva",
  "oly",
  "603",
  "603p",
  "camp",
  "hw",
  "hw_old",
}

local labels = {
  cf = "cf.py - Codeforces",
  atcoder = "atcoder.py - AtCoder",
  qoj = "qoj.py - QOJ",
  codechef = "codechef.py - CodeChef",
  cses = "cses.py - CSES",
  usaco = "usaco.py - USACO",
  uva = "uva.py - UVA",
  oly = "oly.py - olympiad / oj.uz payload",
  ["603"] = "603.py - XC 603 2026",
  ["603p"] = "603p.py - XC 603P 2026",
  camp = "camp.py - XC 603 Summer Camp 2026",
  hw = "hw.py - XC 602 2026 Winter",
  hw_old = "hw_old.py - XC 602 2025",
}

local handlers = {}

local function tests(data)
  return type(data.tests) == "table" and data.tests or {}
end

local function root_or_error(key)
  local root = config.root(key)
  if not root then
    return nil, "base_dir is not configured (set opts.base_dir or BASE_DIR)"
  end
  return root
end

local function prompt(prompt_text, default, done)
  vim.ui.input({ prompt = prompt_text, default = default }, function(value)
    if not value or vim.trim(value) == "" then
      done(nil, "cancelled")
      return
    end
    done(vim.trim(value))
  end)
end

local function prompt_two(first_prompt, second_prompt, done)
  prompt(first_prompt, nil, function(first, err)
    if not first then
      done(nil, nil, err)
      return
    end
    prompt(second_prompt, nil, function(second, second_err)
      if not second then
        done(nil, nil, second_err)
        return
      end
      done(first, second)
    end)
  end)
end

local function make_spec(handler, root, cur, name, data, extra)
  return vim.tbl_extend("force", {
    handler = handler,
    judge = handler,
    root = root,
    cur = cur or "",
    name = name,
    tests = tests(data),
    template = "cf",
    test_layout = "data",
  }, extra or {})
end

local function py_lower_spaces(text)
  return (text or ""):lower():gsub(" ", "_")
end

handlers.cf = function(data, done)
  local root, err = root_or_error("codeforces")
  if not root then
    done(nil, err)
    return
  end

  local name = (data.name or "problem"):match("^([^%.]+)") or "problem"
  name = py_lower_spaces(vim.trim(name))

  local cur = data.group or "codeforces"
  cur = cur:gsub("Codeforces %- ", "")
  cur = cur:gsub("Codeforces Round ", "")
  cur = cur:gsub(" %(", "_")
  cur = cur:gsub("%. ", "_")
  cur = cur:gsub("%)", "")
  cur = cur:gsub("Rated for ", "_")
  cur = cur:gsub(":", ""):gsub(",", ""):gsub(" ", "_"):gsub("!", "")

  done(make_spec("cf", root, cur, name, data))
end

handlers.atcoder = function(data, done)
  local root, err = root_or_error("atcoder")
  if not root then
    done(nil, err)
    return
  end

  local name = (data.name or "problem"):match("^(.-) %- ") or (data.name or "problem")
  name = py_lower_spaces(vim.trim(name))

  local group = data.group or ""
  local lower = group:lower()
  local kinds = {
    { word = "beginner", prefix = "abc" },
    { word = "regular", prefix = "arc" },
    { word = "grand", prefix = "agc" },
    { word = "heuristic", prefix = "ahc" },
  }
  for _, kind in ipairs(kinds) do
    local number = lower:match("atcoder%s+" .. kind.word .. "%s+contest%s+(%d+)")
    if number then
      done(make_spec("atcoder", root, kind.prefix .. number, name, data))
      return
    end
  end

  prompt("Folder Name: ", nil, function(folder, prompt_err)
    if not folder then
      done(nil, prompt_err)
      return
    end
    done(make_spec("atcoder", root, folder, name, data))
  end)
end

local function qoj_problem_id(data)
  local text = (data.url or "") .. " " .. (data.name or "")
  return text:match("/problem/show/(%d+)")
    or text:match("/problem/(%d+)")
    or text:match("#?%s*(%d+)%s*[%.%)%-]")
    or ""
end

handlers.qoj = function(data, done)
  local root, err = root_or_error("qoj")
  if not root then
    done(nil, err)
    return
  end

  local id = qoj_problem_id(data)
  local fallback = id ~= "" and ("problem_" .. id) or "problem"
  local title = data.name or fallback
  title = title:gsub("^#?%s*%d+%s*[%.%)%-]%s*", "")
  local name = util.slugify(title, fallback)
  if id ~= "" and name ~= fallback then
    name = id .. "_" .. name
  end

  done(make_spec("qoj", root, "", name, data))
end

handlers.codechef = function(data, done)
  local root, err = root_or_error("codechef")
  if not root then
    done(nil, err)
    return
  end

  local name = (data.name or "problem"):match("^([^%.]+)") or "problem"
  name = py_lower_spaces(vim.trim(name))

  -- Kept intentionally compatible with the original codechef.py.
  local cur = data.group or "CodeChef"
  cur = cur:gsub("Codeforces %- ", "")
  cur = cur:gsub("Codeforces Round ", "")
  cur = cur:gsub(" %(", "_")
  cur = cur:gsub("%. ", "_")
  cur = cur:gsub("%)", "")
  cur = cur:gsub("Rated for ", "_")
  cur = cur:gsub(" ", "_")

  done(make_spec("codechef", root, cur, name, data))
end

local romans = {
  i = "1",
  ii = "2",
  iii = "3",
  iv = "4",
  v = "5",
  vi = "6",
  vii = "7",
  viii = "8",
  ix = "9",
  x = "10",
}

local function replace_roman_words(text)
  local words = {}
  for word in (text or ""):lower():gmatch("%S+") do
    local prefix, core, suffix = word:match("^([^%a]*)([%a]+)([^%a]*)$")
    if core and romans[core] then
      table.insert(words, (prefix or "") .. romans[core] .. (suffix or ""))
    else
      table.insert(words, word)
    end
  end
  return table.concat(words, " ")
end

handlers.cses = function(data, done)
  local root, err = root_or_error("cses")
  if not root then
    done(nil, err)
    return
  end

  prompt("TOPIC: ", nil, function(topic, prompt_err)
    if not topic then
      done(nil, prompt_err)
      return
    end
    local name = replace_roman_words(data.name or "problem"):gsub(" ", "_")
    done(make_spec("cses", root, topic, name, data))
  end)
end

handlers.usaco = function(data, done)
  local root, err = root_or_error("usaco")
  if not root then
    done(nil, err)
    return
  end

  local raw_name = data.name or "problem"
  local name = raw_name:match("^[^%.]*%.(.*)$") or raw_name
  name = name:gsub("%(Gold%)", "")
  name = py_lower_spaces(vim.trim(name))

  local group = data.group or "USACO"
  local first, division = group:match("^(.-),%s*(.-)$")
  division = (division or "unknown"):lower()
  local contest = first or group
  contest = contest:match(" %- USACO (.*)$") or contest
  contest = contest:gsub(" Contest", "")
  contest = contest:gsub("US Open", "open")
  contest = contest:gsub("December", "dec"):gsub("January", "jan"):gsub("February", "feb")
  contest = contest:gsub(" ", "_")

  done(make_spec("usaco", root, util.join("prev", division, contest), name, data, { template = "usaco" }))
end

handlers.uva = function(data, done)
  local root, err = root_or_error("uva")
  if not root then
    done(nil, err)
    return
  end

  local name = vim.trim(data.name or "problem"):lower()
  name = name:gsub(", ", ""):gsub(" ", "_"):gsub("_%-%_", "_")
  name = name:gsub("!", ""):gsub("%.", ""):gsub(",", ""):gsub("'", ""):gsub('"', "")

  done(make_spec("uva", root, "", name, data))
end

local function first_text(data, keys)
  for _, key in ipairs(keys) do
    local value = data[key]
    if type(value) == "string" and vim.trim(value) ~= "" then
      return vim.trim(value)
    end
  end
  return ""
end

local function collect_texts(value, out)
  if type(value) == "string" then
    local cleaned = vim.trim(value)
    if cleaned ~= "" then
      table.insert(out, cleaned)
    end
  elseif type(value) == "table" then
    for _, item in pairs(value) do
      collect_texts(item, out)
    end
  end
end

local function package_texts(data)
  local out = {}
  for _, key in ipairs({ "packages", "package", "package_name", "package_names", "package_info", "packageInfos" }) do
    if data[key] ~= nil then
      collect_texts(data[key], out)
    end
  end
  return out
end

local function package_label(text)
  if not text or text == "" then
    return ""
  end
  local parts = vim.split(text, "%s*[-:/|]%s*", { trimempty = true })
  local ignored = {
    ioi = true,
    package = true,
    problem = true,
    day = true,
    round = true,
    task = true,
    test = true,
    tests = true,
    sample = true,
  }
  for i = #parts, 1, -1 do
    local part = vim.trim(parts[i])
    local lower = part:lower()
    if part:match("[A-Za-z]") and not ignored[lower] and not lower:match("^%d%d%d%d$") then
      return part
    end
  end
  return ""
end

local function detect_ioi_year(texts)
  for _, text in ipairs(texts) do
    local year = text:match("[Ii][Oo][Ii]%s*[-_/ ]?%s*(%d%d%d%d)")
      or text:match("(%d%d%d%d)%s*[Ii][Oo][Ii]")
      or text:match("[Ii][Oo][Ii]%s*(%d%d)")
    if year then
      return #year == 2 and ("20" .. year) or year
    end
  end
  return nil
end

handlers.oly = function(data, done)
  local root, err = root_or_error("olympiads")
  if not root then
    done(nil, err)
    return
  end

  local title = first_text(data, { "name", "title", "problem", "problem_name" })
  local contest = first_text(data, { "group", "contest", "round", "division" })
  local source = first_text(data, { "source", "site", "judge", "platform" })
  local url = first_text(data, { "url", "link", "problem_url" })
  local packages = package_texts(data)
  local package_name = ""
  for _, text in ipairs(packages) do
    package_name = package_label(text)
    if package_name ~= "" then
      break
    end
  end

  local year_texts = vim.list_extend(vim.deepcopy(packages), { title, contest, source, url })
  local year = detect_ioi_year(year_texts)
  local name = util.slugify(title ~= "" and title or (package_name ~= "" and package_name or (contest ~= "" and contest or "problem")))
  local cur = year and util.join("IOI", "IOI" .. year, name) or util.join("IOI", "IOI", name)

  done(make_spec("oly", root, cur, name, data, { test_layout = "inline" }))
end

local function class_handler(id, folder_prefix, second_label)
  handlers[id] = function(data, done)
    local root, err = root_or_error("classes")
    if not root then
      done(nil, err)
      return
    end

    prompt_two(second_label .. ": ", "NAME: ", function(slot, name, prompt_err)
      if not slot then
        done(nil, prompt_err)
        return
      end
      done(make_spec(id, root, folder_prefix .. slot, name, data))
    end)
  end
end

class_handler("603", "XC_603_2026/Week_", "WEEK")
class_handler("603p", "XC_603P_2026/Week_", "WEEK")
class_handler("hw", "XC_602_2026_Winter/Week_", "WEEK")
class_handler("hw_old", "XC_602_2025/Week_", "WEEK")

handlers.camp = function(data, done)
  local root, err = root_or_error("classes")
  if not root then
    done(nil, err)
    return
  end

  prompt_two("Name: ", "Day: ", function(name, day, prompt_err)
    if not name then
      done(nil, prompt_err)
      return
    end
    done(make_spec("camp", root, "XC_603SummerCamp2026/Day_" .. day, name, data))
  end)
end

local function run_handler(name, data, done)
  local handler = handlers[name]
  if not handler then
    done(nil, "unknown parser: " .. tostring(name))
    return
  end
  handler(data, done)
end

local function detect(data)
  local url = (data.url or ""):lower()
  local source = (data.source or ""):lower()
  local group = (data.group or ""):lower()

  if url:find("oj.uz", 1, true) or source:find("oj.uz", 1, true) then
    return "oly"
  elseif url:find("codeforces.com", 1, true) or group:find("codeforces", 1, true) then
    return "cf"
  elseif url:find("atcoder.jp", 1, true) or group:find("atcoder", 1, true) then
    return "atcoder"
  elseif url:find("qoj.ac", 1, true) or group:match("^qoj") then
    return "qoj"
  elseif url:find("onlinejudge.org", 1, true) or url:find("uva.onlinejudge.org", 1, true) then
    return "uva"
  elseif url:find("codechef.com", 1, true) or group:find("codechef", 1, true) then
    return "codechef"
  elseif url:find("cses.fi", 1, true) or group:find("cses", 1, true) then
    return "cses"
  elseif url:find("usaco.org", 1, true) or group:find("usaco", 1, true) then
    return "usaco"
  end
  return nil
end

local function choose_parser(title, done)
  vim.ui.select(order, {
    prompt = title or "Parser: ",
    format_item = function(name)
      return labels[name] or name
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
  local result = vim.deepcopy(order)
  if include_modes then
    table.insert(result, 1, "manual")
    table.insert(result, 2, "auto")
  end
  return result
end

function M.label(name)
  if name == "manual" or name == nil then
    return "manual"
  end
  if name == "auto" then
    return "auto"
  end
  return labels[name] or name
end

function M.setup(initial)
  if initial == "manual" or initial == "" then
    active = nil
  elseif initial == nil or initial == "auto" or handlers[initial] then
    active = initial
  else
    error("parse.nvim: unknown parser '" .. tostring(initial) .. "'")
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
  if name == "auto" or handlers[name] then
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
    local detected = detect(data)
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
