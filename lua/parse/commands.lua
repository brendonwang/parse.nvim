local M = {}
local handlers = require("parse.handler_registry")
local generator = require("parse.generator")
local server = require("parse.server")
local util = require("parse.util")

local function create(name, callback, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, callback, opts or {})
end

local function open_scratch(name, lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
end

local function payload_lines(payload)
  local encoded = vim.json.encode(payload)
  if vim.fn.executable("jq") == 1 then
    local result = vim.system({ "jq", "." }, { stdin = encoded, text = true }):wait()
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      return vim.split(vim.trim(result.stdout), "\n", { plain = true })
    end
  end
  return vim.split(vim.inspect(payload), "\n", { plain = true })
end

local function alpha_name(index)
  local out = ""
  while index > 0 do
    index = index - 1
    out = string.char(string.byte("a") + (index % 26)) .. out
    index = math.floor(index / 26)
  end
  return out
end

local function first_names(count)
  local names = {}
  for i = 1, count do
    table.insert(names, alpha_name(i))
  end
  return names
end

local function expand_problem_tokens(tokens)
  if #tokens == 0 then
    return nil, "provide problem names, a range like a-f, or a count like 10"
  end

  if #tokens == 2 and tokens[1]:lower() == "first" then
    local count = tonumber(tokens[2])
    if not count or count < 1 or count % 1 ~= 0 then
      return nil, "first must be followed by a positive integer"
    end
    return first_names(count)
  end

  if #tokens == 1 then
    local token = tokens[1]:lower()
    local count = tonumber(token)
      or tonumber(token:match("^first[:=%-]?(%d+)$"))
    if count then
      if count < 1 or count % 1 ~= 0 then
        return nil, "problem count must be a positive integer"
      end
      return first_names(count)
    end
  end

  local names = {}
  local seen = {}
  for _, raw in ipairs(tokens) do
    for token in raw:gmatch("[^,]+") do
      token = vim.trim(token)
      local first, last = token:lower():match("^([a-z])%-([a-z])$")
      if first and last then
        local a, b = first:byte(), last:byte()
        if a > b then
          return nil, "descending problem range is not supported: " .. token
        end
        for code = a, b do
          local name = string.char(code)
          if not seen[name] then
            table.insert(names, name)
            seen[name] = true
          end
        end
      elseif token ~= "" then
        if not token:match("^[%w_.+%-]+$") then
          return nil, "invalid problem name: " .. token
        end
        if not seen[token] then
          table.insert(names, token)
          seen[token] = true
        end
      end
    end
  end

  if #names == 0 then
    return nil, "no problem names provided"
  end
  return names
end

local function current_directory()
  local path = vim.api.nvim_buf_get_name(0)
  if path ~= "" then
    local stat = (vim.uv or vim.loop).fs_stat(path)
    if stat and stat.type == "directory" then
      return path
    end
    return vim.fs.dirname(path)
  end
  return vim.fn.getcwd()
end

function M.setup()
  create("ParseUse", function(cmd)
    if cmd.args == "" then
      handlers.pick_and_set(function(choice)
        if choice then
          util.notify("parser: " .. handlers.label(choice))
        end
      end)
      return
    end

    local ok, err = handlers.set(cmd.args)
    if not ok then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    util.notify("parser: " .. handlers.label(handlers.current()))
  end, {
    nargs = "?",
    complete = function()
      return handlers.names(true)
    end,
  })

  create("ParseStart", function()
    local ok, err = server.start()
    if not ok then
      util.notify("Could not start listener: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)

  create("ParseStop", function()
    server.stop()
  end)

  create("ParseStatus", function()
    local status = server.status()
    util.notify(string.format(
      "%s - http://%s:%d - parser: %s",
      status.running and "running" or "stopped",
      status.host,
      status.port,
      handlers.label(handlers.current())
    ))
  end)

  create("ParseLast", function()
    local payload = require("parse").last_payload
    if not payload then
      util.notify("No Competitive Companion payload has been received yet", vim.log.levels.WARN)
      return
    end
    open_scratch("parse://last-payload.json", payload_lines(payload), "json")
  end)

  create("ParseContest", function(cmd)
    local names, err = expand_problem_tokens(cmd.fargs)
    if not names then
      util.notify(err, vim.log.levels.ERROR)
      return
    end

    local problem_dir = current_directory()
    local results, generation_err = generator.scaffold(problem_dir, names, {
      template = handlers.template(handlers.current()),
    })
    if not results then
      util.notify("Contest scaffold failed: " .. tostring(generation_err), vim.log.levels.ERROR)
      return
    end

    util.notify(string.format("created %d problem%s in %s", #results, #results == 1 and "" or "s", problem_dir))
    if #results > 0 then
      vim.cmd("edit " .. vim.fn.fnameescape(results[1].source))
    end
  end, {
    nargs = "+",
  })
end

M.expand_problem_tokens = expand_problem_tokens
M.alpha_name = alpha_name

return M
