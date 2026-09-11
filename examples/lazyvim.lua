-- ~/.config/nvim/lua/plugins/parse.lua
return {
  {
    "brendonwang/parse.nvim",
    event = "VeryLazy",
    opts = {
      base_dir = vim.env.BASE_DIR,
      auto_start = true,
      open_on_receive = true,

      -- Default: manual. Use :ParseUse <handler> before sending a problem.
      -- Set this to "auto" only if you want URL/group based detection.
      parser = nil,
    },
  },
}
