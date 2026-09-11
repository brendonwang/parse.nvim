local M = {}
local uv = vim.uv or vim.loop

local function sep()
  return package.config:sub(1, 1)
end

function M.expand(path)
  if not path or path == "" then
    return path
  end
  return vim.fs.normalize(vim.fn.expand(path))
end

function M.is_abs(path)
  if not path or path == "" then
    return false
  end
  return path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^%a:") ~= nil
end

function M.join(...)
  local out = nil
  for _, part in ipairs({ ... }) do
    if part and part ~= "" then
      part = tostring(part)
      out = out and (out:gsub("[\\/]+$", "") .. sep() .. part:gsub("^[\\/]+", "")) or part
    end
  end
  return M.expand(out or "")
end

function M.exists(path)
  return path and uv.fs_stat(path) ~= nil
end

function M.is_dir(path)
  local stat = path and uv.fs_stat(path) or nil
  return stat and stat.type == "directory" or false
end

function M.mkdir(path)
  if path and path ~= "" then
    vim.fn.mkdir(path, "p")
  end
end

function M.read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write_file(path, content)
  M.mkdir(vim.fs.dirname(path))
  local file, err = io.open(path, "wb")
  if not file then
    return nil, err
  end
  file:write(content or "")
  file:close()
  return true
end

function M.slugify(text, default)
  text = (text or ""):lower():gsub("%+", " ")
  text = text:gsub("[^a-z0-9]+", "_"):gsub("_+", "_")
  text = text:gsub("^_+", ""):gsub("_+$", "")
  return text ~= "" and text or (default or "problem")
end

function M.safe_segment(text, default)
  text = (text or ""):gsub("[\\/]", "_"):gsub("%s+", "_")
  text = text:gsub("[^%w%._%-]", ""):gsub("_+", "_")
  text = text:gsub("^[_%.]+", ""):gsub("[_%.]+$", "")
  return text ~= "" and text or (default or "problem")
end

function M.host_from_url(url)
  local host = (url or ""):match("^https?://([^/%?#]+)") or ""
  host = host:gsub("^www%.", ""):lower():gsub("[^a-z0-9]+", "")
  return host ~= "" and host or "site"
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "parse.nvim" })
end

function M.runtime_file(path)
  return vim.api.nvim_get_runtime_file(path, false)[1]
end

return M
