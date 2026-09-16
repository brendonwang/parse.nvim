local M = {}
local config = require("parse.config")
local generator = require("parse.generator")
local handlers = require("parse.handler_registry")
local server = require("parse.server")
local util = require("parse.util")

M.last = nil
M.last_payload = nil

local function open_source(path)
  if path and path ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

function M.process(data)
  M.last_payload = vim.deepcopy(data)

  handlers.route(data, function(spec, err)
    if not spec then
      if err ~= "cancelled" then
        util.notify("Could not route problem: " .. tostring(err), vim.log.levels.ERROR)
      end
      return
    end

    local ok, result, generation_err = pcall(generator.generate, spec)
    if not ok then
      util.notify("Generation failed: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    if not result then
      util.notify("Generation failed: " .. tostring(generation_err), vim.log.levels.ERROR)
      return
    end

    M.last = result
    util.notify(string.format("%s -> %s (%d samples)", result.handler or result.judge, result.source, result.tests))
    if config.get().open_on_receive then
      open_source(result.source)
    end
  end)
end

function M.start()
  return server.start()
end

function M.stop()
  server.stop()
end

function M.status()
  return server.status()
end

function M.register_handler(name, definition)
  return handlers.register(name, definition)
end

function M.unregister_handler(name)
  return handlers.unregister(name)
end

function M.setup(opts)
  if vim.fn.has("nvim-0.11.2") ~= 1 then
    error("parse.nvim requires Neovim >= 0.11.2")
  end

  config.setup(opts)
  handlers.setup(config.get().parser)
  require("parse.commands").setup()

  if config.get().auto_start then
    local ok, err = server.start()
    if not ok then
      util.notify("Listener did not start: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

return M
