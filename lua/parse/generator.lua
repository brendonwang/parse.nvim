local M = {}
local config = require("parse.config")
local util = require("parse.util")

local uv = vim.uv or vim.loop

local function cmake_prefix(spec)
  return (spec.cur or ""):gsub("/", "_"):gsub("\\", "_")
end

local function ensure_cmake(spec, problem_dir)
  local path = util.join(problem_dir, "CMakeLists.txt")
  local prefix = cmake_prefix(spec)
  local project = prefix
  if project == "" then
    project = vim.fs.basename(spec.root) or "parse"
  end

  if not util.exists(path) then
    local ok, err = util.write_file(
      path,
      string.format(
        "cmake_minimum_required(VERSION 3.27)\nproject(%s)\n\nset(CMAKE_CXX_STANDARD 17)\n\n",
        project
      )
    )
    if not ok then
      return nil, nil, err
    end
  end

  return path, prefix
end

local function ensure_cmake_target(path, prefix, name)
  local line = string.format("add_executable(%s%s %s.cpp)", prefix, name, name)
  local content, err = util.read_file(path)
  if not content then
    return nil, err
  end
  if content:find(line, 1, true) then
    return true
  end

  local file, open_err = io.open(path, "ab")
  if not file then
    return nil, open_err
  end
  if content ~= "" and content:sub(-1) ~= "\n" then
    file:write("\n")
  end
  file:write(line .. "\n")
  file:close()
  return true
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

local function clear_samples(path)
  if not util.is_dir(path) then
    return
  end
  local scan = uv.fs_scandir(path)
  if not scan then
    return
  end

  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    local is_sample = name:match("^%d+%.in$") or name:match("^%d+%.out$")
    if kind == "file" and is_sample then
      os.remove(util.join(path, name))
    end
  end
end

local function write_tests(spec, problem_dir)
  local inline = spec.test_layout == "inline"
  local test_dir = inline and problem_dir or util.join(spec.root, "data", spec.cur or "", spec.name)
  util.mkdir(test_dir)
  clear_samples(test_dir)

  for i, test in ipairs(spec.tests or {}) do
    local stem = inline and string.format("%02d", i) or tostring(i)
    util.write_file(util.join(test_dir, stem .. ".in"), test.input or "")
    util.write_file(util.join(test_dir, stem .. ".out"), test.output or "")
  end

  return test_dir
end

function M.generate(spec)
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

  local ok, target_err = ensure_cmake_target(cmake, prefix, spec.name)
  if not ok then
    return nil, target_err
  end

  local test_dir = write_tests(spec, problem_dir)
  return {
    source = source,
    problem_dir = problem_dir,
    test_dir = test_dir,
    cmake = cmake,
    tests = #(spec.tests or {}),
    handler = spec.handler,
    judge = spec.judge,
    name = spec.name,
  }
end

return M
