---The two requests a board needs.
---
---The GraphQL lives here rather than in `octo.gh.queries` so the whole feature stays
---in one directory: a board is self-contained, and these strings have no other callers.
local gh = require "octo.gh"

local M = {}

---Search results carry their project status inline, so a board is one request
---rather than one per card.
--- The fields a card is drawn from. Issue and PullRequest are distinct GraphQL types,
--- so the same selection has to be spelled out on each.
local CARD_FIELDS = [[
        number title state url
        repository { nameWithOwner }
        labels(first: 5) { nodes { name } }
        projectItems(first: 10) {
          nodes {
            id
            project { id number title }
            fieldValueByName(name: $statusField) {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
]]

--- Measured: the number of projectItems asked for makes no difference to the response
--- time, so this stays generous enough to find the board among an item's other projects.
local SEARCH_FIELD = [[
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on Issue {
]] .. CARD_FIELDS .. [[
      }
      ... on PullRequest {
]] .. CARD_FIELDS .. [[
      }
    }
  }
]]

--- The status field of a project, whichever way the project is reached.
local PROJECT_FIELD = [[
    projectV2(number: $projectNumber) {
      id
      number
      title
      field(name: $statusField) {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
    }
]]

---Search results carry their project status inline, so a board is one request
---rather than one per card.
M.SEARCH = [[
query($q: String!, $first: Int!, $after: String, $statusField: String!) {
]] .. SEARCH_FIELD .. [[
}
]]

---The board's own column order and the option ids a move has to write.
M.STATUS_FIELD = [[
query($id: ID!, $statusField: String!) {
  node(id: $id) {
    ... on ProjectV2 {
      title
      number
      field(name: $statusField) {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
    }
  }
}
]]

---@class octo.kanban.ProjectRef
---@field owner string
---@field repo string? absent for an organisation project
---@field number integer

---The project a `project:` qualifier names, if the search has one.
---
---GitHub accepts `project:OWNER/NUMBER` for an organisation project and
---`project:OWNER/REPO/NUMBER` for a repository one, so the number is whatever
---trails the last slash — when that is a number at all.
---@param search string?
---@return octo.kanban.ProjectRef?
function M.project_ref(search)
  for value in string.gmatch(search or "", "project:(%S+)") do
    local parts = vim.split(value, "/", { plain = true })
    local number = tonumber(parts[#parts])
    if number and #parts == 2 then
      return { owner = parts[1], number = math.floor(number) }
    elseif number and #parts >= 3 then
      return { owner = parts[1], repo = parts[2], number = math.floor(number) }
    end
  end
  return nil
end

---@param search string?
---@return integer?
function M.project_hint(search)
  local ref = M.project_ref(search)
  return ref and ref.number or nil
end

---Search and project field in a single document.
---
---Two requests cost two `gh` invocations, and each carries about a third of a second
---of process and authentication overhead before GitHub is asked anything. When the
---search already names the project there is no reason to pay that twice.
---@param ref octo.kanban.ProjectRef
---@return string
function M.combined_query(ref)
  local project
  if ref.repo then
    project = [[
  repository(owner: $owner, name: $repoName) {
]] .. PROJECT_FIELD .. [[
  }
]]
  else
    project = [[
  organization(login: $owner) {
]] .. PROJECT_FIELD .. [[
  }
]]
  end

  local header = ref.repo
      and "query($q: String!, $first: Int!, $after: String, $statusField: String!, $owner: String!, $repoName: String!, $projectNumber: Int!) {"
    or "query($q: String!, $first: Int!, $after: String, $statusField: String!, $owner: String!, $projectNumber: Int!) {"

  return header .. "\n" .. SEARCH_FIELD .. project .. "}\n"
end

---@param output string
---@return table?
local function decode(output)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

---Search and board options in one round trip.
---
---Only the first page carries the project selection; later pages are plain searches,
---because the field's options do not change between them.
---@param opts table { search, ref, status_field, max_issues, page_size }
---@param cb fun(nodes: table[]?, project: table?, field: table?, err: string?)
function M.combined(opts, cb)
  local ref = opts.ref
  local status_field = opts.status_field or "Status"
  local max_issues = opts.max_issues or 300
  local page_size = math.min(opts.page_size or 100, 100)

  ---@type table[]
  local collected = {}
  local project, field

  local function page(after)
    local first_page = after == nil
    local fields = {
      q = opts.search,
      first = math.min(page_size, max_issues - #collected),
      statusField = status_field,
    }
    if after then
      fields.after = after
    else
      fields.owner = ref.owner
      fields.projectNumber = ref.number
      if ref.repo then
        fields.repoName = ref.repo
      end
    end

    gh.api.graphql {
      query = first_page and M.combined_query(ref) or M.SEARCH,
      fields = fields,
      opts = {
        cb = function(stdout, stderr)
          if stderr and stderr ~= "" then
            cb(nil, nil, nil, stderr)
            return
          end
          local decoded = decode(stdout)
          local data = decoded and decoded.data
          local result = data and data.search
          if not result then
            cb(nil, nil, nil, "could not read search results")
            return
          end

          if first_page then
            local container = data.organization or data.repository
            local found = container and container.projectV2
            if not found or not found.field or not found.field.id then
              cb(nil, nil, nil, string.format("that project has no single-select field named %q", status_field))
              return
            end
            project = { id = found.id, number = found.number, title = found.title }
            field = found.field
          end

          for _, node in ipairs(result.nodes or {}) do
            collected[#collected + 1] = node
          end

          local info = result.pageInfo or {}
          if info.hasNextPage and #collected < max_issues then
            page(info.endCursor)
          else
            cb(collected, project, field, nil)
          end
        end,
      },
    }
  end

  page(nil)
end

---Fetches search results, following pages until the cap is reached.
---@param opts table { search, status_field, max_issues, page_size }
---@param cb fun(nodes: table[]?, err: string?)
function M.search(opts, cb)
  local status_field = opts.status_field or "Status"
  local max_issues = opts.max_issues or 300
  local page_size = math.min(opts.page_size or 100, 100)

  ---@type table[]
  local collected = {}

  local function page(after)
    local fields = {
      q = opts.search,
      first = math.min(page_size, max_issues - #collected),
      statusField = status_field,
    }
    if after then
      fields.after = after
    end

    gh.api.graphql {
      query = M.SEARCH,
      fields = fields,
      opts = {
        cb = function(stdout, stderr)
          if stderr and stderr ~= "" then
            cb(nil, stderr)
            return
          end
          local decoded = decode(stdout)
          local result = decoded and decoded.data and decoded.data.search
          if not result then
            cb(nil, "could not read search results")
            return
          end

          for _, node in ipairs(result.nodes or {}) do
            collected[#collected + 1] = node
          end

          local info = result.pageInfo or {}
          if info.hasNextPage and #collected < max_issues then
            page(info.endCursor)
          else
            cb(collected, nil)
          end
        end,
      },
    }
  end

  page(nil)
end

---Reads the project's status field: its id, and its options in board order.
---@param project_id string
---@param status_field string?
---@param cb fun(field: table?, err: string?)
function M.status_field(project_id, status_field, cb)
  gh.api.graphql {
    query = M.STATUS_FIELD,
    fields = { id = project_id, statusField = status_field or "Status" },
    opts = {
      cb = function(stdout, stderr)
        if stderr and stderr ~= "" then
          cb(nil, stderr)
          return
        end
        local decoded = decode(stdout)
        local node = decoded and decoded.data and decoded.data.node
        local field = node and node.field
        if not field or not field.id then
          cb(nil, string.format("project has no single-select field named %q", status_field or "Status"))
          return
        end
        cb(field, nil)
      end,
    },
  }
end

return M
