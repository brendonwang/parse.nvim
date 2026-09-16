vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require("parse.config")
local generator = require("parse.generator")
local registry = require("parse.handler_registry")
local commands = require("parse.commands")
local util = require("parse.util")

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(string.format("%s\nexpected: %s\nactual:   %s", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
end

local function contains(text, needle, message)
  if not text:find(needle, 1, true) then
    fail((message or "missing text") .. ": " .. needle .. "\n" .. text)
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

config.setup({
  base_dir = tmp,
  auto_start = false,
  open_on_receive = false,
  cmake = {
    configure = false,
  },
})

local function route(name, payload)
  registry.setup(name)
  local result, route_err
  registry.route(payload, function(spec, err)
    result = spec
    route_err = err
  end)
  truthy(result, "route failed for " .. name .. ": " .. tostring(route_err))
  return result
end

-- Built-in handler regression fixtures.
do
  local spec = route("cf", {
    name = "A. Example Problem",
    group = "Codeforces Round 123 (Div. 2)",
    url = "https://codeforces.com/contest/123/problem/A",
    tests = {},
  })
  eq(spec.root, util.join(tmp, "contests", "codeforce"), "Codeforces root")
  eq(spec.cur, "123_Div_2", "Codeforces contest folder")
  eq(spec.name, "a", "Codeforces problem name")
end

do
  local spec = route("atcoder", {
    name = "A - Past ABCs",
    group = "AtCoder Beginner Contest 350",
    url = "https://atcoder.jp/contests/abc350/tasks/abc350_a",
    tests = {},
  })
  eq(spec.cur, "abc350", "AtCoder contest folder")
  eq(spec.name, "a", "AtCoder problem name")
end

do
  local spec = route("qoj", {
    name = "#1234. Sample Problem",
    url = "https://qoj.ac/problem/1234",
    tests = {},
  })
  eq(spec.cur, "", "QOJ is flat")
  eq(spec.name, "1234_sample_problem", "QOJ problem name")
end

do
  local spec = route("usaco", {
    name = "1. Example Problem (Gold)",
    group = "2024 December Contest, Gold",
    url = "https://usaco.org/index.php?page=viewproblem2",
    tests = {},
  })
  eq(spec.cur, util.join("prev", "gold", "2024_dec"), "USACO contest path")
  eq(spec.name, "example_problem", "USACO problem name")
  eq(spec.template, "usaco", "USACO template")
end

-- Handler registry: config overrides and auto-detection.
do
  config.setup({
    base_dir = tmp,
    auto_start = false,
    open_on_receive = false,
    cmake = { configure = false },
    handlers = {
      cf = {
        label = "My Codeforces",
        priority = 100,
        detect = function(data)
          return (data.url or ""):find("codeforces.com", 1, true) ~= nil
        end,
        parse = function(data, done)
          done({
            handler = "cf",
            judge = "cf",
            root = tmp,
            cur = "override",
            name = data.name,
            tests = {},
            template = "cf",
          })
        end,
      },
    },
  })
  registry.setup("auto")
  local spec
  registry.route({ url = "https://codeforces.com/problemset/problem/1/A", name = "custom" }, function(value)
    spec = value
  end)
  truthy(spec, "custom auto-detected handler did not run")
  eq(spec.cur, "override", "custom handler overrides built-in")
  eq(registry.label("cf"), "My Codeforces", "custom handler label")
end

-- Restore baseline config for generator tests.
config.setup({
  base_dir = tmp,
  auto_start = false,
  open_on_receive = false,
  cmake = {
    minimum_version = "3.20",
    cxx_standard = 20,
    export_compile_commands = true,
    configure = false,
    target_name_formatter = function()
      return "my target/a"
    end,
  },
})
registry.setup("cf")

-- CMake generation, sanitization, configurable settings, and duplicate repair.
do
  local root = util.join(tmp, "cmake")
  local spec = {
    root = root,
    cur = "Round 1",
    name = "a",
    tests = {},
    template = "cf",
    handler = "test",
    judge = "test",
  }

  local result, err = generator.generate(spec)
  truthy(result, "generator failed: " .. tostring(err))
  eq(result.target, "my_target_a", "target name sanitization")

  local cmake = assert(util.read_file(result.cmake))
  contains(cmake, "cmake_minimum_required(VERSION 3.20)", "minimum CMake version")
  contains(cmake, "set(CMAKE_CXX_STANDARD 20)", "C++ standard")
  contains(cmake, "set(CMAKE_EXPORT_COMPILE_COMMANDS ON)", "compile commands export")
  contains(cmake, "add_executable(my_target_a a.cpp)", "formatted target")

  local again = assert(generator.generate(spec))
  local repeated = assert(util.read_file(again.cmake))
  local _, occurrences = repeated:gsub("add_executable%(my_target_a a%.cpp%)", "")
  eq(occurrences, 1, "CMake target should not be duplicated")
end

-- Contest problem expansion.
do
  local names = assert(commands.expand_problem_tokens({ "a-f" }))
  eq(names, { "a", "b", "c", "d", "e", "f" }, "a-f expansion")

  names = assert(commands.expand_problem_tokens({ "10" }))
  eq(names, { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }, "count expansion")

  names = assert(commands.expand_problem_tokens({ "first", "3" }))
  eq(names, { "a", "b", "c" }, "first N expansion")

  names = assert(commands.expand_problem_tokens({ "a", "c", "x-y" }))
  eq(names, { "a", "c", "x", "y" }, "explicit/range expansion")

  eq(commands.alpha_name(26), "z", "26th alphabetic name")
  eq(commands.alpha_name(27), "aa", "27th alphabetic name")
end

-- Batch scaffolding should create all sources and one CMake target per problem.
do
  config.setup({
    base_dir = tmp,
    auto_start = false,
    open_on_receive = false,
    cmake = { configure = false },
  })
  local dir = util.join(tmp, "Contest")
  local results, err = generator.scaffold(dir, { "a", "b", "c" })
  truthy(results, "scaffold failed: " .. tostring(err))
  eq(#results, 3, "scaffold result count")
  truthy(util.exists(util.join(dir, "a.cpp")), "a.cpp missing")
  truthy(util.exists(util.join(dir, "b.cpp")), "b.cpp missing")
  truthy(util.exists(util.join(dir, "c.cpp")), "c.cpp missing")

  local cmake = assert(util.read_file(util.join(dir, "CMakeLists.txt")))
  contains(cmake, "add_executable(Contesta a.cpp)", "a target")
  contains(cmake, "add_executable(Contestb b.cpp)", "b target")
  contains(cmake, "add_executable(Contestc c.cpp)", "c target")
end

vim.fn.delete(tmp, "rf")
print("parse.nvim regression tests: OK")
