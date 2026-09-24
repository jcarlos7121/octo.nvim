---The board's colours.
---
---Linked rather than hardcoded. A board is read against whatever colourscheme the
---reader has on, and octo's own palette is fixed hex — `OctoGrey` is #2A354C, which
---is nearly invisible on a dark background and wrong on a light one. Linking to the
---standard groups every colourscheme defines means the board follows the theme,
---including a switch from a dark one to a light one.
local M = {}

---Every group the renderer emits, and what it defers to.
M.links = {
  OctoKanbanHeader = "Title", -- column name and count
  OctoKanbanRule = "LineNr", -- the line under a column header
  -- Open work reads green and finished work greys out, the way GitHub's own icons
  -- do. The Diagnostic* groups are Neovim's own, so every colourscheme has them
  -- and they are picked to stay legible against that scheme's background.
  OctoKanbanNumber = "DiagnosticOk", -- an open card's number
  OctoKanbanDone = "Comment", -- a closed or merged card's number, receding
  OctoKanbanRepo = "Comment", -- the repository on a card, when the board spans several
  OctoKanbanLabel = "DiagnosticHint", -- a label with no colour of its own
}

---`default = true` throughout, so anyone who sets one of these keeps it.
function M.apply()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

---Colourschemes clear every highlight group when they load, taking these links with
---them, so they are put back each time one is applied.
function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("octo_kanban_colors", { clear = true }),
    callback = M.apply,
  })
end

return M
