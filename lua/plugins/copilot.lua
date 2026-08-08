-- GitHub Copilot, as inline ghost text only.
--
-- Deliberately NOT wired into the completion menu. Copilot and the LSP answer
-- different questions -- the LSP knows what exists, Copilot guesses what you
-- meant -- and mixing them into one ranked list makes both worse. Ghost text
-- sits out of the way until you want it.
--
-- Nothing here touches `blink.cmp` (AstroNvim v5's completion engine), so the
-- normal completion menu behaves exactly as upstream intends.
--
-- Toggles live under `<Leader>a` -- see `ai.lua`.
---@type LazySpec
return {
  "zbirenbaum/copilot.lua",
  cmd = "Copilot",
  event = "InsertEnter",
  build = ":Copilot auth",
  opts = {
    panel = { enabled = false },
    suggestion = {
      enabled = true,
      auto_trigger = true,
      keymap = {
        -- `accept` is off on purpose: the obvious key for it is <Tab>, and
        -- blink.cmp owns <Tab> for selecting the next completion item. Accept a
        -- whole line with <M-l> instead, which nothing else claims.
        accept = false,
        accept_word = false,
        accept_line = "<M-l>",
        next = "<M-]>",
        prev = "<M-[>",
        dismiss = "<C-]>",
      },
    },
    filetypes = {},
  },
}
