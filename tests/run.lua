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
    fail(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message or "assertion failed",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
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
tmp = (vim.uv or vim.loop).fs_realpath(tmp)

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
  })
  eq(spec.cur, "abc350", "AtCoder contest folder")
  eq(spec.name, "a", "AtCoder problem name")
end

do
  local spec = route("qoj", {
    name = "#1234. Sample Problem",
    url = "https://qoj.ac/problem/1234",
  })
  eq(spec.cur, "", "QOJ is flat")
  eq(spec.name, "1234_sample_problem", "QOJ problem name")
end

do
  local spec = route("usaco", {
    name = "1. Example Problem (Gold)",
    group = "2024 December Contest, Gold",
    url = "https://usaco.org/index.php?page=viewproblem2",
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

-- The handler root keeps one active add_subdirectory entry for the latest problem directory.
do
  local class_root = util.join(tmp, "USACO_Classes")
  util.mkdir(class_root)
  assert(util.write_file(
    util.join(class_root, "CMakeLists.txt"),
    table.concat({
      "cmake_minimum_required(VERSION 3.24)",
      "project(USACO_Classes)",
      "",
      "set(CMAKE_CXX_STANDARD 17)",
      "",
      "#add_subdirectory(XC_603P/Week_13)",
      "add_subdirectory(Mock_Silver/Test_10)",
      "add_subdirectory(XC_603_2026/Week_8)",
      "",
    }, "\n")
  ))

  config.setup({
    base_dir = tmp,
    auto_start = false,
    open_on_receive = false,
    cmake = {
      build_dir = "out",
      link_compile_commands = true,
      configure = false,
    },
  })

  local first = assert(generator.generate({
    root = class_root,
    cur = util.join("XC_603_2026", "Week_11"),
    name = "binary_tree_on_plane",
    template = "cf",
    handler = "603",
    judge = "603",
  }))

  eq(first.project_root, class_root, "handler root should be the CMake project root")
  local root_cmake = assert(util.read_file(util.join(class_root, "CMakeLists.txt")))
  contains(root_cmake, "add_subdirectory(Mock_Silver/Test_10)", "older root subdirectory should be preserved")
  contains(root_cmake, "add_subdirectory(XC_603_2026/Week_11)", "latest root subdirectory should be updated")
  truthy(not root_cmake:find("add_subdirectory(XC_603_2026/Week_8)", 1, true), "previous latest subdirectory was not replaced")
  contains(root_cmake, "#add_subdirectory(XC_603P/Week_13)", "commented root subdirectory should be preserved")

  local child_cmake = assert(util.read_file(util.join(class_root, "XC_603_2026", "Week_11", "CMakeLists.txt")))
  contains(child_cmake, "project(XC_603_2026_Week_11)", "child CMake project")
  contains(
    child_cmake,
    "add_executable(XC_603_2026_Week_11binary_tree_on_plane binary_tree_on_plane.cpp)",
    "child target"
  )

  local second = assert(generator.generate({
    root = class_root,
    cur = util.join("XC_603_2026", "Week_12"),
    name = "next_problem",
    template = "cf",
    handler = "603",
    judge = "603",
  }))
  eq(second.project_root, class_root, "second handler root")
  root_cmake = assert(util.read_file(util.join(class_root, "CMakeLists.txt")))
  contains(root_cmake, "add_subdirectory(XC_603_2026/Week_12)", "latest subdirectory should move forward")
  truthy(not root_cmake:find("add_subdirectory(XC_603_2026/Week_11)", 1, true), "active subdirectories stacked up")
  truthy(not util.exists(util.join(class_root, "XC_603_2026", "Week_11", "out")), "child out directory created")
  truthy(not util.exists(util.join(class_root, "XC_603_2026", "Week_12", "out")), "second child out directory created")
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

-- Incoming samples use the original gen.py data layout.
do
  require("parse").setup({
    base_dir = tmp,
    auto_start = false,
    open_on_receive = false,
    parser = "cf",
    cmake = { configure = false },
  })
  local payload = {
    name = "A. Sample files",
    group = "Codeforces Round 456",
    tests = {
      { input = "first input\n", output = "first output\n" },
      { input = "second input\n", output = "second output\n" },
    },
  }
  local spec = route("cf", payload)
  eq(spec.tests, nil, "routing should stay independent of testcase payloads")

  require("parse").process(payload)
  local result = assert(require("parse").last)
  local data_dir = util.join(spec.root, "data", spec.cur, spec.name)
  eq(util.read_file(util.join(data_dir, "1.in")), "first input\n", "first sample input")
  eq(util.read_file(util.join(data_dir, "1.out")), "first output\n", "first sample output")
  eq(util.read_file(util.join(data_dir, "2.in")), "second input\n", "second sample input")
  eq(util.read_file(util.join(data_dir, "2.out")), "second output\n", "second sample output")

  -- gen.py only called gen_data() when it successfully created the source file.
  -- Re-importing an existing problem therefore preserves edited testcase files.
  assert(util.write_file(util.join(data_dir, "1.in"), "keep input"))
  assert(util.write_file(util.join(data_dir, "1.out"), "keep output"))
  assert(util.write_file(result.source, "// keep my solution"))
  require("parse").process(payload)
  eq(util.read_file(util.join(data_dir, "1.in")), "keep input", "reimport changed existing input")
  eq(util.read_file(util.join(data_dir, "1.out")), "keep output", "reimport changed existing output")
  eq(util.read_file(result.source), "// keep my solution", "reimport changed solution")
end

-- New-file command: personal/configured templates, prompts, validation, no overwrite.
do
  local base = util.join(tmp, "new-files")
  local dir = util.join(base, "contest")
  util.mkdir(dir)
  local cf = "// personal CF\nint main() {}\n"
  local usaco = "// personal USACO\nint main() {}\n"
  assert(util.write_file(util.join(base, "algo/library/template_cf.cpp"), cf))
  assert(util.write_file(util.join(base, "algo/library/template_usaco.cpp"), usaco))
  config.setup({ base_dir = base, auto_start = false, cmake = { configure = false } })
  registry.setup("cf")
  commands.setup()
  local cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(dir)
  vim.cmd("enew")
  vim.cmd("ParseNew cf a")
  eq(util.read_file(util.join(dir, "a.cpp")), cf, "CF personal template")
  eq(vim.api.nvim_buf_get_name(0), util.join(dir, "a.cpp"), "new file should open")
  -- A named buffer's directory takes precedence over the working directory.
  vim.api.nvim_set_current_dir(base)
  vim.cmd("ParseNew usaco gates.cpp")
  eq(util.read_file(util.join(dir, "gates.cpp")), usaco, "USACO personal template and extension")
  contains(
    assert(util.read_file(util.join(dir, "CMakeLists.txt"))),
    "add_executable(contestgates gates.cpp)",
    "new-file CMake target"
  )
  registry.set("usaco")
  vim.cmd("ParseNew default")
  eq(util.read_file(util.join(dir, "default.cpp")), usaco, "active parser template")

  local input, notify = vim.ui.input, vim.notify
  local messages = {}
  vim.notify = function(message)
    table.insert(messages, message)
  end
  vim.ui.input = function(_, done)
    done("prompted")
  end
  vim.cmd("ParseNew cf")
  eq(util.read_file(util.join(dir, "prompted.cpp")), cf, "prompted name")
  vim.ui.input = function(_, done)
    done("implicit")
  end
  vim.cmd("ParseNew")
  eq(util.read_file(util.join(dir, "implicit.cpp")), usaco, "no-argument prompt template")
  local before = vim.fn.readdir(dir)
  local cmake_before = util.read_file(util.join(dir, "CMakeLists.txt"))
  vim.ui.input = function(_, done)
    done(nil)
  end
  vim.cmd("ParseNew")
  vim.ui.input = function(_, done)
    done(" ")
  end
  vim.cmd("ParseNew")
  vim.cmd("ParseNew cf ../escape")
  vim.cmd("ParseNew cf extra arguments")
  vim.cmd("ParseNew usaco a")
  truthy(#messages >= 3, "invalid/existing filenames should report errors")
  eq(vim.fn.readdir(dir), before, "cancelled/invalid/duplicate request changed directory")
  eq(
    util.read_file(util.join(dir, "CMakeLists.txt")),
    cmake_before,
    "cancelled/invalid/duplicate request changed CMake"
  )
  eq(util.read_file(util.join(dir, "a.cpp")), cf, "existing file was replaced")
  vim.ui.input, vim.notify = input, notify

  config.setup({
    base_dir = base,
    templates = { cf = util.join(base, "algo/library/template_usaco.cpp") },
    cmake = { configure = false },
  })
  vim.cmd("ParseNew cf override")
  eq(util.read_file(util.join(dir, "override.cpp")), usaco, "configured template takes precedence")
  config.setup({ base_dir = util.join(tmp, "no-personal-templates"), cmake = { configure = false } })
  vim.cmd("ParseNew cf bundled")
  eq(
    util.read_file(util.join(dir, "bundled.cpp")),
    util.read_file(util.runtime_file("templates/parse.nvim/cf.cpp")),
    "bundled fallback"
  )
  truthy(not util.exists(util.join(base, "data")), "new-file command created test data")
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, "parse://scratch")
  vim.cmd("ParseNew cf from_scratch")
  eq(vim.api.nvim_buf_get_name(0), util.join(base, "from_scratch.cpp"), "scratch buffer should use cwd")
  vim.api.nvim_set_current_dir(cwd)
end

vim.fn.delete(tmp, "rf")
print("parse.nvim regression tests: OK")
