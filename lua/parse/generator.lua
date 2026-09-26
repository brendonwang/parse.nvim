local M = {}
local config = require("parse.config")
local util = require("parse.util")

local uv = vim.uv or vim.loop

local function cmake_prefix(spec)
  return (spec.cur or ""):gsub("/", "_"):gsub("\\", "_")
end

local function sanitize_cmake_name(name, fallback)
  name = tostring(name or "")
  name = name:gsub("[^%w_.+%-]", "_")
  name = name:gsub("_+", "_")
  name = name:gsub("^_+", ""):gsub("_+$", "")
  if name == "" then
    return fallback or "target"
  end
  return name
end

local function cmake_target_name(spec, prefix)
  local default_name = prefix .. spec.name
  local formatter = config.get().cmake.target_name_formatter
  local name = default_name

  if type(formatter) == "function" then
    local ok, formatted = pcall(formatter, default_name, spec)
    if ok and formatted ~= nil then
      name = formatted
    elseif not ok then
      util.notify("CMake target formatter failed: " .. tostring(formatted), vim.log.levels.WARN)
    end
  end

  return sanitize_cmake_name(name, sanitize_cmake_name(default_name, "target"))
end

local function ensure_cmake(spec, problem_dir)
  local path = util.join(problem_dir, "CMakeLists.txt")
  local prefix = cmake_prefix(spec)
  local project = prefix
  if project == "" then
    project = vim.fs.basename(spec.root) or vim.fs.basename(problem_dir) or "parse"
  end
  project = sanitize_cmake_name(project, "parse")

  if not util.exists(path) then
    local cmake = config.get().cmake
    local export = cmake.export_compile_commands and "set(CMAKE_EXPORT_COMPILE_COMMANDS ON)\n\n" or ""
    local ok, err = util.write_file(
      path,
      string.format(
        "cmake_minimum_required(VERSION %s)\nproject(%s)\n\nset(CMAKE_CXX_STANDARD %s)\n%s",
        tostring(cmake.minimum_version),
        project,
        tostring(cmake.cxx_standard),
        export
      )
    )
    if not ok then
      return nil, nil, err
    end
  end

  return path, prefix
end

local function ensure_cmake_target(path, spec, prefix)
  local target = cmake_target_name(spec, prefix)
  local line = string.format("add_executable(%s %s.cpp)", target, spec.name)
  local content, err = util.read_file(path)
  if not content then
    return nil, nil, err
  end
  if content:find(line, 1, true) then
    return true, target
  end

  local file, open_err = io.open(path, "ab")
  if not file then
    return nil, nil, open_err
  end
  if content ~= "" and content:sub(-1) ~= "\n" then
    file:write("\n")
  end
  file:write(line .. "\n")
  file:close()
  return true, target
end

local function write_source(spec, problem_dir)
  local source = util.join(problem_dir, spec.name .. ".cpp")
  if util.exists(source) then
    return source
  end

  local template = config.template(spec.template or "cf")
  local content = template and util.read_file(template) or nil
  if not content then
    return nil, "could not read template for " .. tostring(spec.template or "cf")
  end

  local ok, err = util.write_file(source, content)
  if not ok then
    return nil, err
  end
  return source
end

local function compile_entry_key(entry)
  if type(entry) ~= "table" or type(entry.file) ~= "string" or entry.file == "" then
    return nil
  end

  local file = entry.file
  if not util.is_abs(file) and type(entry.directory) == "string" and entry.directory ~= "" then
    file = util.join(entry.directory, file)
  end
  return vim.fs.normalize(file)
end

local function decode_compile_commands(content)
  if not content or vim.trim(content) == "" then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil
  end
  return decoded
end

local function publish_compile_commands(problem_dir, build_dir)
  local cmake = config.get().cmake
  if not cmake.link_compile_commands then
    return true
  end

  local source = util.join(problem_dir, build_dir, "compile_commands.json")
  if not util.exists(source) then
    return true
  end

  local source_content, source_err = util.read_file(source)
  if not source_content then
    return nil, source_err
  end
  local incoming = decode_compile_commands(source_content)
  if not incoming then
    return nil, "CMake produced an invalid compile_commands.json"
  end

  local root = config.base_dir() or problem_dir
  local destination = util.join(root, "compile_commands.json")
  local existing = {}
  local stat = uv.fs_lstat(destination)

  -- Older versions created per-directory symlinks. A root symlink is also safe
  -- to replace because parse.nvim itself owns symlink destinations.
  if stat and stat.type == "link" then
    os.remove(destination)
    stat = nil
  end

  if stat then
    local content, read_err = util.read_file(destination)
    if not content then
      return nil, read_err
    end
    existing = decode_compile_commands(content)
    if not existing then
      return nil, "refusing to overwrite invalid root compile_commands.json"
    end
  end

  local by_file = {}
  local keys = {}
  local function add(entries)
    for _, entry in ipairs(entries) do
      local key = compile_entry_key(entry)
      if key then
        if not by_file[key] then
          table.insert(keys, key)
        end
        by_file[key] = entry
      end
    end
  end

  add(existing)
  add(incoming)
  table.sort(keys)

  local merged = {}
  for _, key in ipairs(keys) do
    table.insert(merged, by_file[key])
  end

  local ok, write_err = util.write_file(destination, vim.json.encode(merged) .. "\n")
  if not ok then
    return nil, write_err
  end

  -- Clean up the legacy visible symlink in the problem directory if present.
  local legacy = util.join(problem_dir, "compile_commands.json")
  if legacy ~= destination then
    local legacy_stat = uv.fs_lstat(legacy)
    if legacy_stat and legacy_stat.type == "link" then
      os.remove(legacy)
    end
  end

  return true
end

function M.configure(problem_dir)
  local cmake = config.get().cmake
  if not cmake.configure or vim.fn.executable("cmake") ~= 1 then
    return false
  end

  local build_dir = cmake.build_dir or ".build"
  local command = {
    "cmake",
    "-S",
    ".",
    "-B",
    build_dir,
    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
  }
  vim.list_extend(command, cmake.configure_args or {})
  vim.system(command, { cwd = problem_dir, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        util.notify("CMake configure failed: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
        return
      end
      local published, publish_err = publish_compile_commands(problem_dir, build_dir)
      if not published then
        util.notify("Could not update root compile_commands.json: " .. tostring(publish_err), vim.log.levels.WARN)
      end
    end)
  end)
  return true
end

local function generate_one(spec)
  if not spec or not spec.root or not spec.name then
    return nil, "invalid generation spec"
  end

  local problem_dir = util.join(spec.root, spec.cur or "")
  util.mkdir(problem_dir)

  local cmake, prefix, cmake_err = ensure_cmake(spec, problem_dir)
  if not cmake then
    return nil, cmake_err
  end

  local source, err = write_source(spec, problem_dir)
  if not source then
    return nil, err
  end

  local ok, target, target_err = ensure_cmake_target(cmake, spec, prefix)
  if not ok then
    return nil, target_err
  end

  return {
    source = source,
    problem_dir = problem_dir,
    cmake = cmake,
    target = target,
    handler = spec.handler,
    judge = spec.judge,
    name = spec.name,
  }
end

function M.generate(spec)
  local result, err = generate_one(spec)
  if not result then
    return nil, err
  end
  M.configure(result.problem_dir)
  return result
end

function M.scaffold(problem_dir, names, opts)
  opts = opts or {}
  if not problem_dir or problem_dir == "" or type(names) ~= "table" or #names == 0 then
    return nil, "invalid scaffold request"
  end

  problem_dir = util.expand(problem_dir)
  util.mkdir(problem_dir)

  local root = vim.fs.dirname(problem_dir)
  local cur = vim.fs.basename(problem_dir)
  local results = {}
  for _, name in ipairs(names) do
    local result, err = generate_one({
      root = root,
      cur = cur,
      name = name,
      template = opts.template or "cf",
      handler = "scaffold",
      judge = "scaffold",
    })
    if not result then
      return nil, err
    end
    table.insert(results, result)
  end

  M.configure(problem_dir)
  return results
end

M.sanitize_cmake_name = sanitize_cmake_name
M._publish_compile_commands = publish_compile_commands

return M
