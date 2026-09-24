---The two requests a board needs.
---
---The GraphQL lives here rather than in `octo.gh.queries` so the whole feature stays
---in one directory: a board is self-contained, and these strings have no other callers.
local gh = require "octo.gh"

local M = {}

---Search results carry their project status inline, so a board is one request
---rather than one per card.
M.SEARCH = [[
query($q: String!, $first: Int!, $after: String, $statusField: String!) {
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on Issue {
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
      }
      ... on PullRequest {
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
      }
    }
  }
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

---The project number named by a `project:` qualifier, if the search has one.
---
---GitHub accepts `project:OWNER/NUMBER` and `project:OWNER/REPO/NUMBER`, so the
---number is whatever trails the last slash — when that is a number at all.
---@param search string?
---@return integer?
function M.project_hint(search)
  for value in string.gmatch(search or "", "project:(%S+)") do
    local last = string.match(value, "([^/]+)$")
    local number = last and tonumber(last) or nil
    if number then
      return math.floor(number)
    end
  end
  return nil
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
