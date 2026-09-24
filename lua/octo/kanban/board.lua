---Turns search results into the ordered columns of a project board.
---
---Everything here is pure: it takes the data a search returned plus the project's
---own Status options, and returns columns. No requests, no buffers, no Neovim
---state, so the grouping rules can be exercised directly in tests.
local M = {}

---Cards whose status the board does not offer collect here.
local NO_STATUS = "No Status"

---@class octo.kanban.Project
---@field id string
---@field number integer
---@field title string

---@class octo.kanban.Label
---@field name string
---@field color string? six-digit hex, without the leading #

---@class octo.kanban.Card
---@field number integer
---@field title string
---@field state string
---@field url string?
---@field repo string?
---@field labels octo.kanban.Label[]
---@field status string?
---@field item_id string? project item id; absent when the card is not on the board
---@field is_pr boolean

---@class octo.kanban.Column
---@field name string
---@field option_id string? absent for the No Status column, which cannot be written to
---@field cards octo.kanban.Card[]

---Which project the board should be drawn from.
---
---A search can return items belonging to several projects. Without an explicit
---choice the busiest one wins, which is almost always the board the query meant.
---@param nodes table[] search result nodes
---@param wanted_number integer? pin the board to this project number
---@return octo.kanban.Project?
function M.choose_project(nodes, wanted_number)
  ---@type table<string, octo.kanban.Project>
  local projects = {}
  ---@type table<string, integer>
  local counts = {}
  ---@type string[]
  local order = {}

  for _, node in ipairs(nodes or {}) do
    local items = node.projectItems and node.projectItems.nodes or {}
    for _, item in ipairs(items) do
      local project = item.project
      if project and project.id then
        if not projects[project.id] then
          projects[project.id] = project
          counts[project.id] = 0
          order[#order + 1] = project.id
        end
        counts[project.id] = counts[project.id] + 1
      end
    end
  end

  if wanted_number then
    for _, id in ipairs(order) do
      if projects[id].number == wanted_number then
        return projects[id]
      end
    end
    return nil
  end

  ---@type string?
  local best
  for _, id in ipairs(order) do
    if not best or counts[id] > counts[best] then
      best = id
    end
  end
  return best and projects[best] or nil
end

---Flattens search results into cards, reading each one's status on the chosen board.
---@param nodes table[] search result nodes
---@param project_id string
---@return octo.kanban.Card[]
function M.normalize(nodes, project_id)
  ---@type octo.kanban.Card[]
  local cards = {}

  for _, node in ipairs(nodes or {}) do
    ---@type string?
    local status
    ---@type string?
    local item_id
    local items = node.projectItems and node.projectItems.nodes or {}
    for _, item in ipairs(items) do
      if item.project and item.project.id == project_id then
        item_id = item.id
        status = item.fieldValueByName and item.fieldValueByName.name or nil
        break
      end
    end

    ---@type octo.kanban.Label[]
    local labels = {}
    for _, label in ipairs(node.labels and node.labels.nodes or {}) do
      -- the colour comes along so a label can render as its own badge
      labels[#labels + 1] = { name = label.name, color = label.color ~= vim.NIL and label.color or nil }
    end

    cards[#cards + 1] = {
      number = node.number,
      title = node.title,
      state = node.state,
      url = node.url,
      repo = node.repository and node.repository.nameWithOwner or nil,
      labels = labels,
      status = status,
      item_id = item_id,
      is_pr = node.__typename == "PullRequest",
    }
  end

  return cards
end

---Distributes cards across the board's columns.
---
---Column order comes from the project's Status field rather than from the results,
---so a column nothing landed in still appears — an empty column is information.
---@param cards octo.kanban.Card[]
---@param options table[] status options in board order, each { id, name }
---@return octo.kanban.Column[]
function M.columns(cards, options)
  ---@type table<string, octo.kanban.Column>
  local by_name = {}
  ---@type octo.kanban.Column[]
  local columns = {}

  for _, option in ipairs(options or {}) do
    local column = { name = option.name, option_id = option.id, cards = {} }
    by_name[option.name] = column
    columns[#columns + 1] = column
  end

  ---@type octo.kanban.Column
  local unplaced = { name = NO_STATUS, cards = {} }
  for _, card in ipairs(cards or {}) do
    -- a status the board no longer offers is as good as none
    local column = card.status and by_name[card.status] or nil
    if column then
      column.cards[#column.cards + 1] = card
    else
      unplaced.cards[#unplaced.cards + 1] = card
    end
  end

  if #unplaced.cards > 0 then
    table.insert(columns, 1, unplaced)
  end

  return columns
end

return M
