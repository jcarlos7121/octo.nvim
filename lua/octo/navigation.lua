local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local constants = require "octo.constants"
local utils = require "octo.utils"

local vim = vim

local M = {}

---Open the PR one position up (away from the base) or down (toward the base)
---in the current PR's stack. Does nothing at either end of the stack.
---@param offset 1|-1
function M.go_to_stack_neighbor(offset)
  local buffer = utils.get_current_buffer()
  if not buffer or not buffer:isPullRequest() then
    return
  end
  local stack_entry = buffer:pullRequest().stackEntry
  if stack_entry == nil or stack_entry == vim.NIL or utils.is_blank(stack_entry.stack) then
    utils.info "PR is not part of a stack"
    return
  end
  local target_position = stack_entry.position + offset ---@type integer
  for _, entry in ipairs(stack_entry.stack.entries.nodes) do
    if entry.position == target_position then
      if utils.is_blank(entry.pullRequest) then
        utils.info("The stacked PR at position " .. tostring(target_position) .. " is not accessible")
        return
      end
      utils.get_pull_request(entry.pullRequest.number, buffer.repo)
      return
    end
  end
  -- already at that end of the stack: do nothing
end

--[[
Opens a url in your default browser, bypassing gh.

@param url The url to open.
]]
---@param url string
function M.open_in_browser_raw(url)
  local os_name = vim.uv.os_uname().sysname
  local is_windows = vim.uv.os_uname().version:match "Windows"

  if os_name == "Darwin" then
    os.execute("open " .. url)
  elseif os_name == "Linux" then
    os.execute("xdg-open " .. url)
  elseif is_windows then
    os.execute("start " .. url)
  end
end

---@param kind? "issue"|"pull_request"|"discussion"|"repo"|"gist"|"project"|"workflow_run"|"release"
---@param repo? string|{ url: string }
---@param number? integer|string
function M.open_in_browser(kind, repo, number)
  if not kind and not repo then
    local buffer = utils.get_current_buffer()
    if not buffer then
      local owner_repo = utils.get_remote_name()
      if not owner_repo then
        utils.error "No remote repository found"
        return
      end
      gh.repo.view {
        owner_repo,
        web = true,
      }
      return
    end
    if buffer:isPullRequest() then
      gh.pr.view {
        buffer.number,
        repo = buffer.repo,
        web = true,
      }
    elseif buffer:isIssue() then
      gh.issue.view {
        buffer.number,
        repo = buffer.repo,
        web = true,
      }
    elseif buffer:isRepo() then
      gh.repo.view {
        buffer.repo,
        web = true,
      }
    elseif buffer:isDiscussion() then
      M.open_in_browser_raw(buffer:discussion().url)
    elseif buffer:isRelease() then
      gh.release.view {
        buffer:release().tagName,
        repo = buffer.repo,
        web = true,
      }
    end
  else
    if kind == "pr" or kind == "pull_request" then
      assert(repo, "repo is required")
      gh.pr.view {
        number,
        repo = repo,
        web = true,
      }
    elseif kind == "issue" then
      assert(repo, "repo is required")
      gh.issue.view {
        number,
        repo = repo,
        web = true,
      }
    elseif kind == "repo" then
      assert(repo, "repo is required")
      gh.repo.view {
        type(repo) == "table" and repo.url or repo,
        web = true,
      }
    elseif kind == "gist" then
      gh.gist.view {
        number,
        web = true,
      }
    elseif kind == "project" then
      assert(repo, "repo is required")
      gh.project.view {
        number,
        owner = repo,
        web = true,
      }
    elseif kind == "workflow_run" then
      gh.run.view {
        number,
        web = true,
      }
    elseif kind == "release" then
      assert(repo, "repo is required")
      gh.release.view {
        number,
        repo = repo,
        web = true,
      }
    end
  end
end

local function open_file_if_found(path, line)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type then
    vim.cmd("e " .. path)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    return true
  end
  return false
end

function M.go_to_file()
  local bufnr = vim.api.nvim_get_current_buf()
  ---@type string?
  local path = ""
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if utils.in_diff_window(bufnr) then
    _, path = utils.get_split_and_path(bufnr)
  else
    local buffer = octo_buffers[bufnr]
    if not buffer then
      return
    end
    if not buffer:isPullRequest() then
      return
    end
    local _thread = buffer:get_thread_at_cursor()
    path, line = _thread.path, _thread.line
  end
  local result = open_file_if_found(utils.path_join { vim.fn.getcwd(), path }, line)
  if not result then
    local cmd = "git rev-parse --show-toplevel"
    local git_root = vim.fn.system(cmd):gsub("\n", "")
    result = open_file_if_found(utils.path_join { git_root, path }, line)
  end
  if not result then
    utils.error "Cannot find file in CWD or git path"
  end
end

---@param link octo.LinkedReference
local function open_reference(link)
  -- a type check rather than `is_blank`: it narrows for the language server
  local url = link.url
  if type(url) == "string" and url ~= "" then
    M.open_in_browser_raw(url)
    return
  end
  local repo, number = link.repo, link.number
  if type(repo) == "string" and type(number) == "number" then
    utils.open_buffer(repo, number)
  end
end

---Open whatever the cursor is on: an issue or pull request reference, a link,
---or a deployment.
---
---A reference written in the text wins, since the cursor is literally on it,
---and a plain URL in the text after that. Failing both, the line's own links
---answer -- the "Development:" and "Deployments:" lines and the timeline's
---events are virtual text, so there is no column to read there.
function M.go_to_link()
  local buffer = utils.get_current_buffer()
  if not buffer then
    return
  end

  local repo, number = utils.extract_issue_at_cursor(buffer.repo)
  if repo ~= nil and number ~= nil then
    utils.open_buffer(repo, number)
    return
  end

  local url = utils.extract_pattern_at_cursor(constants.MARKDOWN_URL_PATTERN)
    or utils.extract_pattern_at_cursor(constants.URL_PATTERN)
  if type(url) == "string" and url ~= "" then
    M.open_in_browser_raw(url)
    return
  end

  local links = buffer.linkByLine and buffer.linkByLine[vim.fn.line "."]
  if links == nil or #links == 0 then
    utils.info "Nothing to open on this line"
    return
  end

  if #links == 1 then
    open_reference(links[1])
    return
  end

  vim.ui.select(links, {
    prompt = "Open which one?",
    ---@param link octo.LinkedReference
    format_item = function(link)
      if link.kind == "deployment" then
        return link.title
      end
      return string.format("%s#%d %s", link.repo == buffer.repo and "" or link.repo, link.number, link.title)
    end,
  }, function(link)
    if link ~= nil then
      open_reference(link)
    end
  end)
end

function M.go_to_issue()
  local buffer = utils.get_current_buffer()
  if not buffer then
    return
  end
  local repo, number = utils.extract_issue_at_cursor(buffer.repo)
  if not repo or not number then
    return
  end
  utils.open_buffer(repo, number)
end

function M.next_comment()
  local buffer = utils.get_current_buffer()
  if buffer and buffer.kind then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = utils.get_sorted_comment_lines(buffer.bufnr)
    if not buffer:isReviewThread() then
      -- skil title and body
      lines = utils.tbl_slice(lines, 3, #lines)
    end
    if not lines or not current_line then
      return
    end

    if #lines == 0 then
      return
    end

    ---@type integer?
    local target
    if current_line < lines[1] + 1 then
      -- go to first comment
      target = lines[1] + 1
    elseif current_line > lines[#lines] + 1 then
      -- do not move
      target = current_line - 1
    else
      for i = #lines, 1, -1 do
        if current_line >= lines[i] + 1 then
          target = lines[i + 1] + 1
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { target + 1, cursor[2] })
  end
end

function M.prev_comment()
  local buffer = utils.get_current_buffer()
  if buffer and buffer.kind then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = utils.get_sorted_comment_lines(buffer.bufnr)
    lines = utils.tbl_slice(lines, 3, #lines)
    if not lines or not current_line then
      return
    end

    if #lines == 0 then
      return
    end

    ---@type integer?
    local target
    if current_line > lines[#lines] + 2 then
      -- go to last comment
      target = lines[#lines] + 1
    elseif current_line <= lines[1] + 2 then
      -- do not move
      target = current_line - 1
    else
      for i = 1, #lines, 1 do
        if current_line <= lines[i] + 2 then
          target = lines[i - 1] + 1
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { target + 1, cursor[2] })
  end
end

return M
