local gh = require "octo.gh"
local mutations = require "octo.gh.mutations"
local queries = require "octo.gh.queries"
local utils = require "octo.utils"
local vim = vim

---A review comment can carry a replacement for the lines it was left on -- the
---```suggestion block behind GitHub's "Commit suggestion" button. GitHub has no
---API for that button, but a suggestion is a mechanical edit: put the block
---where the comment points, on the pull request's head branch. That is what
---this does, and it shows the reader what the edit is first.
local M = {}

---@class octo.Suggestion
---@field thread_id string
---@field path string
---@field start_line integer first line it replaces, as the file stands now
---@field end_line integer last line it replaces
---@field side string RIGHT or LEFT
---@field outdated boolean the lines it was left on have moved on since
---@field lines string[] what it puts there
---@field replaced string[] what it takes away, read off the diff hunk

---Suggestion blocks in a comment body, in the order they appear
---@param body string?
---@return string[][]
function M.parse(body)
  local blocks = {} ---@type string[][]
  local current = nil ---@type string[]?
  for _, line in ipairs(vim.split(body or "", "\n")) do
    if current ~= nil then
      if line:match "^%s*```" ~= nil then
        table.insert(blocks, current)
        current = nil
      else
        table.insert(current, (line:gsub("\r$", "")))
      end
    elseif line:match "^%s*```+%s*suggestion" ~= nil then
      current = {}
    end
  end
  -- GitHub takes an unterminated fence as running to the end of the comment
  if current ~= nil then
    table.insert(blocks, current)
  end
  return blocks
end

---The lines a suggestion replaces, read off the diff hunk the comment was left
---on: a diff of one side only says half of what is about to happen.
---@param diffhunk string?
---@param side string?
---@param start_line integer
---@param end_line integer
---@return string[]
function M.replaced_lines(diffhunk, side, start_line, end_line)
  if utils.is_blank(diffhunk) then
    return {}
  end
  local hunk_lines = vim.split(diffhunk, "\n")
  local ok, map = pcall(utils.generate_position2line_map, diffhunk)
  if not ok or map == nil then
    return {}
  end
  local side_lines = side == "LEFT" and map.left_side_lines or map.right_side_lines

  local positions = {} ---@type integer[]
  for position, file_line in pairs(side_lines or {}) do
    local number = tonumber(file_line)
    if number ~= nil and number >= start_line and number <= end_line then
      table.insert(positions, position)
    end
  end
  table.sort(positions)

  local replaced = {} ---@type string[]
  for _, position in ipairs(positions) do
    -- every hunk line but the header carries a marker in the first column
    table.insert(replaced, (hunk_lines[position] or ""):sub(2))
  end
  return replaced
end

---Where the pull request's branch lives, and whether it can be written to
---@param repo string
---@param number integer
---@param cb fun(head: { repo: string, ref: string, writable: boolean }): nil
local function head_branch(repo, number, cb)
  local owner, name = utils.split_repo(repo)
  gh.api.graphql {
    query = queries.pull_request_head_branch,
    F = { owner = owner, name = name, number = number },
    jq = ".data.repository.pullRequest",
    opts = {
      cb = gh.create_callback {
        failure = function(stderr)
          utils.error(utils.is_blank(stderr) and "Cannot read the pull request's branch" or stderr)
        end,
        success = function(output)
          local pr = vim.json.decode(output)
          local head_repo = vim.tbl_get(pr, "headRepository", "nameWithOwner") or repo
          -- a fork's branch is only ours to write to when the author allows it
          local writable = not pr.isCrossRepository or pr.maintainerCanModify == true
          cb { repo = head_repo, ref = pr.headRefName, writable = writable }
        end,
      },
    },
  }
end

---@param lines string[]
---@return string
local function encode(lines)
  return vim.base64.encode(table.concat(lines, "\n"))
end

---@param content string base64 from the contents API, wrapped in newlines
---@return string[]
local function decode(content)
  local decoded = vim.base64.decode((content:gsub("%s", "")))
  local lines = vim.split(decoded, "\n")
  return lines
end

---Put a suggestion where the comment points, on the head branch, and resolve the
---thread as GitHub does when the button is used.
---@param suggestion octo.Suggestion
---@param repo string
---@param number integer
---@param cb? fun(applied: boolean): nil
function M.commit(suggestion, repo, number, cb)
  cb = cb or function() end

  if suggestion.outdated then
    utils.error "The lines this suggestion was left on have moved: apply it by hand"
    cb(false)
    return
  end
  if suggestion.side == "LEFT" then
    utils.error "This suggestion is on the old side of the diff and cannot be committed"
    cb(false)
    return
  end

  head_branch(repo, number, function(head)
    if not head.writable then
      utils.error "This pull request comes from a fork that does not allow edits from maintainers"
      cb(false)
      return
    end

    gh.api.get {
      "/repos/{repo}/contents/{path}",
      format = { repo = head.repo, path = suggestion.path },
      F = { ref = head.ref },
      opts = {
        cb = gh.create_callback {
          failure = function(stderr)
            utils.error(utils.is_blank(stderr) and "Cannot read " .. suggestion.path or stderr)
            cb(false)
          end,
          success = function(output)
            local file = vim.json.decode(output)
            if type(file.content) ~= "string" then
              utils.error(suggestion.path .. " is not a file this can edit")
              cb(false)
              return
            end
            local lines = decode(file.content)

            if suggestion.end_line > #lines then
              utils.error(string.format("%s has only %d lines: the suggestion points past it", suggestion.path, #lines))
              cb(false)
              return
            end

            -- what is there now has to be what the suggestion replaces, or the
            -- file has moved on and committing would undo somebody's work
            for offset, expected in ipairs(suggestion.replaced) do
              local actual = lines[suggestion.start_line + offset - 1]
              if actual ~= nil and vim.trim(actual) ~= vim.trim(expected) then
                utils.error(
                  string.format(
                    "%s:%d has changed since the suggestion was made",
                    suggestion.path,
                    suggestion.start_line + offset - 1
                  )
                )
                cb(false)
                return
              end
            end

            local updated = {} ---@type string[]
            for index = 1, suggestion.start_line - 1 do
              table.insert(updated, lines[index])
            end
            for _, line in ipairs(suggestion.lines) do
              table.insert(updated, line)
            end
            for index = suggestion.end_line + 1, #lines do
              table.insert(updated, lines[index])
            end

            gh.api.put {
              "/repos/{repo}/contents/{path}",
              format = { repo = head.repo, path = suggestion.path },
              F = {
                message = "Apply suggestion from code review",
                content = encode(updated),
                sha = file.sha,
                branch = head.ref,
              },
              opts = {
                cb = gh.create_callback {
                  failure = function(stderr)
                    utils.error(utils.is_blank(stderr) and "Cannot commit the suggestion" or stderr)
                    cb(false)
                  end,
                  success = function()
                    utils.info(string.format("Committed the suggestion to %s on %s", suggestion.path, head.ref))
                    M.resolve(suggestion.thread_id, function()
                      cb(true)
                    end)
                  end,
                },
              },
            }
          end,
        },
      },
    }
  end)
end

---The suggestions of the comment the cursor is in, with the buffer they came
---from -- the comment body is where they live, so anywhere in it will do.
---@return octo.Suggestion[]?, OctoBuffer?
local function at_cursor()
  local buffer = utils.get_current_buffer()
  if buffer == nil then
    return nil, nil
  end
  local found = buffer.suggestionByLine and buffer.suggestionByLine[vim.fn.line "."]
  if found == nil or #found == 0 then
    utils.info "No suggestion on this comment"
    return nil, nil
  end
  return found, buffer
end

---@param suggestions octo.Suggestion[]
---@param prompt string
---@param cb fun(suggestion: octo.Suggestion): nil
local function pick(suggestions, prompt, cb)
  if #suggestions == 1 then
    cb(suggestions[1])
    return
  end
  vim.ui.select(suggestions, {
    prompt = prompt,
    ---@param suggestion octo.Suggestion
    format_item = function(suggestion)
      local first = suggestion.lines[1] or ""
      return string.format("%s:%d  %s", suggestion.path, suggestion.start_line, vim.trim(first))
    end,
  }, function(suggestion)
    if suggestion ~= nil then
      cb(suggestion)
    end
  end)
end

---Commit the suggestion the cursor is in, the way the button on the pull request
---page does: the edit lands on the head branch and the thread is resolved.
function M.commit_at_cursor()
  local found, buffer = at_cursor()
  if found == nil or buffer == nil then
    return
  end
  pick(found, "Commit which suggestion?", function(suggestion)
    local answer = vim.fn.confirm(
      string.format(
        "Commit this suggestion to %s?\n  %s, line%s %s\n\nIt becomes a commit on the pull request's branch.",
        buffer.repo,
        suggestion.path,
        suggestion.start_line == suggestion.end_line and "" or "s",
        suggestion.start_line == suggestion.end_line and tostring(suggestion.start_line)
          or string.format("%d-%d", suggestion.start_line, suggestion.end_line)
      ),
      "&Yes\n&No",
      2
    )
    if answer ~= 1 then
      return
    end
    M.commit(suggestion, buffer.repo, buffer.number, function(applied)
      if applied then
        require("octo").load_buffer { bufnr = buffer.bufnr }
      end
    end)
  end)
end

---Turn the suggestion down: GitHub has no such button, and resolving the thread
---is what it means -- the suggestion stays readable, and stops asking.
function M.dismiss_at_cursor()
  local found, buffer = at_cursor()
  if found == nil or buffer == nil then
    return
  end
  local thread_id = found[1].thread_id
  M.resolve(thread_id, function()
    utils.info "Suggestion turned down: the thread is resolved"
    require("octo").load_buffer { bufnr = buffer.bufnr }
  end)
end

---Mark the thread a suggestion belongs to as resolved: GitHub does this when the
---suggestion is committed, and it is also the only way to turn one down.
---@param thread_id string
---@param cb? fun(): nil
function M.resolve(thread_id, cb)
  gh.api.graphql {
    query = mutations.resolve_thread,
    F = { id = thread_id },
    jq = ".data.resolveReviewThread.thread.isResolved",
    opts = {
      cb = gh.create_callback {
        failure = function(stderr)
          utils.error(utils.is_blank(stderr) and "Cannot resolve the thread" or stderr)
        end,
        success = function()
          if cb ~= nil then
            cb()
          end
        end,
      },
    },
  }
end

return M
