---@return string?
local function launch_dir()
  local argc = vim.fn.argc(-1) -- args nvim *started* with, not the current arglist
  if argc == 0 then return vim.fn.getcwd() end
  if argc > 1 then return nil end
  local arg = vim.fn.argv(0) --[[@as string]]
  if vim.fn.isdirectory(arg) == 0 then return nil end
  return (vim.fn.fnamemodify(arg, ":p"):gsub("/$", ""))
end

--- Whether we actually have a saved session for that directory. Checked before
--- startup so we only suppress neo-tree when there is something to put in its
--- place -- `nvim <dir>` in an unvisited directory should still open the tree.
---@return boolean
local function has_dirsession()
  local dir = launch_dir()
  if not dir then return false end
  local ok, util = pcall(require, "resession.util")
  if not ok then return false end
  return vim.fn.filereadable(util.get_session_file(dir, "dirsession")) == 1
end

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@type AstroCoreOpts
    opts = {
      sessions = {
        autosave = {
          last = true, -- always save a "Last Session"
          cwd = true, -- save a session for the current directory
        },
      },
      autocmds = {
        restore_dirsession = {
          {
            event = "VimEnter",
            desc = "Restore the session for this directory when nvim opens on a directory",
            nested = true, -- let other autocmds (LSP, treesitter, ...) fire as buffers load
            callback = function()
              local dir = launch_dir()
              if not dir then return end
              if dir ~= vim.fn.getcwd() then vim.cmd.cd(vim.fn.fnameescape(dir)) end
              -- Scheduled so the rest of startup finishes first; resession's
              -- own reset then closes whatever is on screen before it rebuilds
              -- the layout.
              vim.schedule(function() require("resession").load(dir, { dir = "dirsession", silence_errors = true }) end)
            end,
          },
        },
      },
    },
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    optional = true,
    opts = function(_, opts)
      if has_dirsession() then
        opts.filesystem = opts.filesystem or {}
        opts.filesystem.hijack_netrw_behavior = "disabled"
      end
    end,
  },
}
