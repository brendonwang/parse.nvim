local M = {}
local handlers = require("parse.handlers")
local server = require("parse.server")
local util = require("parse.util")

local function create(name, callback, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, callback, opts or {})
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
end

return M
