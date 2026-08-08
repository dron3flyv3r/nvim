-- Session restore.
--
-- AstroNvim already ships `resession.nvim` and already *saves* a session on exit
-- (see `astrocore.sessions.autosave`, which writes both a "Last Session" and a
-- per-directory "dirsession"). What it does not do by default is *restore* one
-- automatically, so this adds that.
--
-- THE GOTCHA THIS FILE EXISTS FOR: `nvim` and `nvim .` are not the same thing.
-- `nvim .` launches with one argument, so a naive `argc(-1) == 0` guard skips
-- the restore and you get neo-tree on an empty slate instead of your session.
-- We handle three cases:
--
--     nvim          -> restore the dirsession for the current directory
--     nvim <dir>    -> cd into <dir>, then restore *its* dirsession
--     nvim <file>   -> untouched, no restore
--
-- So the loop you want works: `:qa` writes the session for the cwd, and
-- `nvim .` in that same directory brings back the buffers/splits/tabs.

--- The directory this nvim was launched to work in, or nil if it was launched
--- on a file (or on several arguments), in which case we stay out of the way.
---
--- Normalised to an absolute path with no trailing slash, because that is
--- exactly the spelling `getcwd()` will report once we've cd'd there -- and
--- `getcwd()` is what autosave used as the session name on the way out.
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
              vim.schedule(
                function() require("resession").load(dir, { dir = "dirsession", silence_errors = true }) end
              )
            end,
          },
        },
      },
    },
  },
  {
    -- neo-tree hijacks a directory buffer to show its tree, but it does the
    -- actual work on a 10ms debounce -- so it lands *after* our restore and
    -- plants the tree in the window that should be holding your first file.
    -- Flipping the config later can't stop an already-queued hijack, so when we
    -- know a session is coming, don't let it arm in the first place.
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
