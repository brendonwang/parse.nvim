local M = {}
local config = require("parse.config")
local util = require("parse.util")

local uv = vim.uv or vim.loop
local server = nil

local status_text = {
  [200] = "OK",
  [202] = "Accepted",
  [204] = "No Content",
  [400] = "Bad Request",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [413] = "Payload Too Large",
  [500] = "Internal Server Error",
}

local function response(code, body)
  body = body or ""
  return table.concat({
    "HTTP/1.1 " .. tostring(code) .. " " .. (status_text[code] or "OK"),
    "Content-Type: application/json; charset=utf-8",
    "Content-Length: " .. tostring(#body),
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Headers: Content-Type",
    "Access-Control-Allow-Methods: POST, GET, OPTIONS",
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

local function finish(client, code, body)
  if not client or client:is_closing() then
    return
  end
  client:write(response(code, body), function()
    if not client:is_closing() then
      client:shutdown(function()
        if not client:is_closing() then
          client:close()
        end
      end)
    end
  end)
end

local function handle_request(client, raw)
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    finish(client, 400, vim.json.encode({ status = "error", message = "malformed request" }))
    return
  end
  local header = raw:sub(1, header_end - 1)
  local content_length = tonumber(header:lower():match("content%-length:%s*(%d+)")) or 0
  local body = raw:sub(header_end + 4, header_end + 3 + content_length)
  local method, path = header:match("^(%u+)%s+([^%s]+)")

  if method == "OPTIONS" then
    finish(client, 204, "")
    return
  end

  if method == "GET" and (path == "/health" or path == "/") then
    finish(client, 200, vim.json.encode({ status = "ok", service = "parse.nvim" }))
    return
  end

  if method ~= "POST" or path ~= "/" then
    finish(client, method == "POST" and 404 or 405, vim.json.encode({ status = "error" }))
    return
  end

  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then
    finish(client, 400, vim.json.encode({ status = "error", message = "invalid JSON" }))
    return
  end

  finish(client, 202, vim.json.encode({ status = "accepted" }))
  vim.schedule(function()
    local ok_process, err = pcall(function()
      require("parse").process(data)
    end)
    if not ok_process then
      util.notify("Failed to process payload: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function attach_client(client)
  local chunks = {}
  local received = 0
  local expected = nil
  local max_body = config.get().max_body_bytes

  client:read_start(function(err, chunk)
    if err then
      finish(client, 400, vim.json.encode({ status = "error", message = tostring(err) }))
      return
    end
    if not chunk then
      return
    end

    received = received + #chunk
    if received > max_body + 16384 then
      client:read_stop()
      finish(client, 413, vim.json.encode({ status = "error", message = "payload too large" }))
      return
    end

    table.insert(chunks, chunk)
    local raw = table.concat(chunks)
    local header_end = raw:find("\r\n\r\n", 1, true)
    if header_end and expected == nil then
      local header = raw:sub(1, header_end - 1):lower()
      expected = tonumber(header:match("content%-length:%s*(%d+)")) or 0
      if expected > max_body then
        client:read_stop()
        finish(client, 413, vim.json.encode({ status = "error", message = "payload too large" }))
        return
      end
    end

    if header_end and expected ~= nil then
      local body_bytes = #raw - (header_end + 3)
      if body_bytes >= expected then
        client:read_stop()
        handle_request(client, raw)
      end
    end
  end)
end

function M.start()
  if server and not server:is_closing() then
    return true
  end

  local opts = config.get()
  local tcp = uv.new_tcp()
  local ok_bind, bind_err = pcall(tcp.bind, tcp, opts.host, opts.port)
  if not ok_bind then
    pcall(tcp.close, tcp)
    return nil, tostring(bind_err)
  end

  local ok_listen, listen_err = pcall(tcp.listen, tcp, 128, function(err)
    if err then
      vim.schedule(function()
        util.notify("Listener error: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end
    local client = uv.new_tcp()
    local ok_accept, accept_err = pcall(tcp.accept, tcp, client)
    if not ok_accept then
      client:close()
      vim.schedule(function()
        util.notify("Accept error: " .. tostring(accept_err), vim.log.levels.ERROR)
      end)
      return
    end
    attach_client(client)
  end)

  if not ok_listen then
    pcall(tcp.close, tcp)
    return nil, tostring(listen_err)
  end

  server = tcp
  return true
end

function M.stop()
  if server and not server:is_closing() then
    server:close()
  end
  server = nil
end

function M.running()
  return server ~= nil and not server:is_closing()
end

function M.status()
  local opts = config.get()
  return {
    running = M.running(),
    host = opts.host,
    port = opts.port,
  }
end

return M
