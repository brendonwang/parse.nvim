local M = {}
local util = require("parse.util")

M.defaults = {
  base_dir = vim.env.BASE_DIR,
  host = "127.0.0.1",
  port = 10043,
  auto_start = true,
  open_on_receive = true,
  max_body_bytes = 2 * 1024 * 1024,

  -- nil/manual = never infer the parser. Pick with :ParseUse.
  -- "auto" = infer when possible, then fall back to the parser picker.
  parser = nil,

  roots = {
    codeforces = "contests/codeforce",
    atcoder = "contests/AtCoder",
    qoj = "contests/QOJ",
    -- Matches the original codechef.py, which wrote into the Codeforces tree.
    codechef = "contests/codeforce",
    cses = "contests/CSES",
    uva = "contests/uva",
    usaco = "usaco",
    olympiads = "olympiads",
    classes = "USACO_Classes",
  },

  templates = {
    cf = nil,
    usaco = nil,
  },

  cmake = {
    minimum_version = "3.27",
    cxx_standard = 17,
    export_compile_commands = true,
    configure = true,
    build_dir = ".build",
    link_compile_commands = true,
    -- Optional function(default_name, spec) -> target name.
    -- The returned name is sanitized before it is written to CMakeLists.txt.
    target_name_formatter = nil,
  },

  -- Register new handlers or partially override built-ins. Set a handler to
  -- false to disable it. See require("parse").register_handler() for the same
  -- definition format at runtime.
  handlers = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if M.options.base_dir then
    M.options.base_dir = util.expand(M.options.base_dir)
  end
  return M.options
end

function M.get()
  return M.options
end

function M.base_dir()
  local base = M.options.base_dir or vim.env.BASE_DIR
  if not base or base == "" then
    return nil
  end
  return util.expand(base)
end

function M.root(key)
  local root = M.options.roots[key]
  if not root then
    return nil
  end
  if util.is_abs(root) then
    return util.expand(root)
  end
  local base = M.base_dir()
  return base and util.join(base, root) or nil
end

function M.template(kind)
  local configured = M.options.templates[kind]
  if configured and configured ~= "" then
    return util.expand(configured)
  end

  local base = M.base_dir()
  if base then
    local original = util.join(base, "algo", "library", kind == "usaco" and "template_usaco.cpp" or "template_cf.cpp")
    if util.exists(original) then
      return original
    end
  end

  return util.runtime_file("templates/parse.nvim/" .. (kind == "usaco" and "usaco.cpp" or "cf.cpp"))
end

return M
