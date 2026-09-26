local M = {}
local config = require("parse.config")
local util = require("parse.util")

local uv = vim.uv or vim.loop
local server = nil
local handoff_pending = false
local handoff_client = nil

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

  if method == "POST" and path == "/__takeover" then
    local peer = client:getpeername()
    local ip = peer and peer.ip or ""
    if ip ~= "127.0.0.1" and ip ~= "::1" and not ip:match("^::ffff:127%.") then
      finish(client, 403, vim.json.encode({ status = "error" }))
      return
    end
    finish(client, 202, vim.json.encode({ status = "taking_over" }))
    vim.schedule(function()
      M.stop()
      util.notify("Listener handed off to another Neovim instance")
    end)
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

local function bind(opts)
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

local function stop_handoff()
  handoff_pending = false
  if handoff_client then
    pcall(handoff_client.read_stop, handoff_client)
    if not handoff_client:is_closing() then
      handoff_client:close()
    end
    handoff_client = nil
  end
end

local function retry_bind(opts, attempts)
  if not handoff_pending then
    return
  end
  local ok, err = bind(opts)
  if ok then
    stop_handoff()
    util.notify("Listener moved to this Neovim instance")
    return
  end
  if attempts >= 20 then
    stop_handoff()
    util.notify("Could not take over parse.nvim listener: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  -- ponytail: simultaneous handoffs are first-bind-wins; add a shared lock if they become common.
  vim.defer_fn(function()
    retry_bind(opts, attempts + 1)
  end, 50)
end

local function request_handoff(opts)
  if handoff_pending then
    return true
  end
  handoff_pending = true
  local client = uv.new_tcp()
  handoff_client = client
  local host = (opts.host == "0.0.0.0" or opts.host == "::") and "127.0.0.1" or opts.host
  client:connect(host, opts.port, function(err)
    if not handoff_pending then
      return
    end
    if err then
      retry_bind(opts, 0)
      return
    end
    local response_buffer = ""
    client:read_start(function(read_err, chunk)
      if not handoff_pending then
        return
      end
      if read_err or not chunk then
        stop_handoff()
        util.notify(
          "Could not hand off parse.nvim listener" .. (read_err and (": " .. tostring(read_err)) or ""),
          vim.log.levels.ERROR
        )
        return
      end
      response_buffer = response_buffer .. chunk
      local status = response_buffer:match("^HTTP/1%.1 (%d%d%d)")
      if not status then
        return
      end
      pcall(client.read_stop, client)
      if not client:is_closing() then
        client:close()
      end
      handoff_client = nil
      if status ~= "202" then
        stop_handoff()
        util.notify("The port is occupied by a service that is not parse.nvim", vim.log.levels.ERROR)
        return
      end
      retry_bind(opts, 0)
    end)
    client:write(table.concat({
      "POST /__takeover HTTP/1.1",
      "Host: " .. host .. ":" .. tostring(opts.port),
      "Content-Length: 0",
      "Connection: close",
      "",
      "",
    }, "\r\n"))
    vim.defer_fn(function()
      if handoff_pending then
        stop_handoff()
        util.notify("Timed out requesting parse.nvim listener handoff", vim.log.levels.ERROR)
      end
    end, 2000)
  end)
  return true
end

function M.start()
  if server and not server:is_closing() then
    return true
  end
  if handoff_pending then
    return true
  end

  local opts = config.get()
  local ok, err = bind(opts)
  if ok then
    return true
  end
  if err:find("EADDRINUSE", 1, true) or err:lower():find("address already in use", 1, true) then
    return request_handoff(opts)
  end
  return nil, err
end

function M.stop()
  stop_handoff()
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
    handoff_pending = handoff_pending,
    host = opts.host,
    port = opts.port,
  }
end

return M
