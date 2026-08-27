local config = require "octo.config"
local utils = require "octo.utils"
local vim = vim

---Keeps a buffer up to date on a timer, so watching a review land or a workflow
---run progress does not mean reaching for the refresh key. Refreshing rewrites
---the buffer, so a watch holds still whenever the reader is in the middle of
---something: an unsent comment, or any mode other than normal in that buffer.
local M = {}

---@alias octo.AutoRefreshKind "issue"|"pull"|"discussion"|"run"

---@class octo.AutoRefreshEntry
---@field kind octo.AutoRefreshKind what the buffer holds, and so how to refresh it
---@field paused boolean whether the last tick held still

---@type table<integer, octo.AutoRefreshEntry>
local watched = {}

-- luv's own types are not part of the checked runtime, so the handle is untyped
---@type any
local timer = nil

---What a buffer holds, when it is something this can refresh
---@param bufnr integer
---@return octo.AutoRefreshKind?
function M.kind_of(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local octo_buf = octo_buffers and octo_buffers[bufnr]
  if octo_buf ~= nil then
    local kind = octo_buf.kind
    if kind == "issue" then
      return "issue"
    elseif kind == "pull" then
      return "pull"
    elseif kind == "discussion" then
      return "discussion"
    end
    return nil
  end
  if vim.api.nvim_buf_get_name(bufnr):match "octo%-workflow%-run:" ~= nil then
    return "run"
  end
  return nil
end

---Whether refreshing now would trample what the reader is doing
---@param bufnr integer
---@return boolean
function M.editing(bufnr)
  -- insert, visual, anything but normal: the buffer is being worked on
  if vim.api.nvim_get_current_buf() == bufnr and vim.fn.mode() ~= "n" then
    return true
  end
  local octo_buf = octo_buffers and octo_buffers[bufnr]
  if octo_buf == nil then
    return false
  end
  return utils.buffer_has_local_edits(octo_buf)
end

---Refresh a buffer. Answers false when there is nothing left to watch for.
---@param bufnr integer
---@param entry octo.AutoRefreshEntry
---@return boolean keep_watching
local function refresh(bufnr, entry)
  if entry.kind == "run" then
    local runs = require "octo.workflow_runs"
    -- the run view keeps one buffer at a time: refetching for any other would
    -- render the wrong run into it
    if runs.buf ~= bufnr or runs.current_wf == nil then
      return true
    end
    -- a finished run has nothing more to show, and refetching one is a
    -- synchronous round trip: stop rather than spend it every interval
    if runs.current_wf.status == "completed" then
      if config.values.auto_refresh.notify then
        utils.info "Auto refresh off: the workflow run finished"
      end
      return false
    end
    pcall(runs.refetch)
    return true
  end

  require("octo").load_buffer { bufnr = bufnr }
  return true
end

---@param entry octo.AutoRefreshEntry
---@param paused boolean
local function announce(entry, paused)
  if entry.paused == paused then
    return
  end
  entry.paused = paused
  if not config.values.auto_refresh.notify then
    return
  end
  if paused then
    utils.info "Auto refresh is holding still while this buffer has unsent edits"
  else
    utils.info "Auto refresh resumed"
  end
end

local function stop_timer()
  if timer ~= nil then
    timer:stop()
    timer:close()
    timer = nil
  end
end

---Refresh every watched buffer that is not being edited. Public so the interval
---is not the only way to drive it.
function M.tick()
  for bufnr, entry in pairs(watched) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      watched[bufnr] = nil
    elseif M.editing(bufnr) then
      announce(entry, true)
    else
      announce(entry, false)
      if not refresh(bufnr, entry) then
        watched[bufnr] = nil
      end
    end
  end

  if vim.tbl_count(watched) == 0 then
    stop_timer()
  end
end

local function start_timer()
  if timer ~= nil then
    return
  end
  local interval = config.values.auto_refresh.interval
  timer = vim.uv.new_timer()
  if timer == nil then
    utils.error "Cannot start the auto refresh timer"
    return
  end
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      M.tick()
    end)
  )
end

---@param bufnr integer
---@return boolean
function M.is_watching(bufnr)
  return watched[bufnr] ~= nil
end

---Stop refreshing a buffer
---@param bufnr integer
function M.unwatch(bufnr)
  watched[bufnr] = nil
  if vim.tbl_count(watched) == 0 then
    stop_timer()
  end
end

---Start or stop refreshing a buffer on the interval
---@param bufnr? integer defaults to the current buffer
---@return boolean watching
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if M.is_watching(bufnr) then
    M.unwatch(bufnr)
    utils.info "Auto refresh off"
    return false
  end

  local kind = M.kind_of(bufnr)
  if kind == nil then
    utils.info "Auto refresh works in issue, pull request, discussion and workflow run buffers"
    return false
  end

  if kind == "run" then
    local runs = require "octo.workflow_runs"
    local run = runs.buf == bufnr and runs.current_wf or nil
    if run ~= nil and run.status == "completed" then
      utils.info "This workflow run has finished: nothing left to refresh"
      return false
    end
  end

  watched[bufnr] = { kind = kind, paused = false }
  start_timer()
  utils.info(string.format("Auto refresh on, every %gs", config.values.auto_refresh.interval / 1000))
  return true
end

---Which buffers are being refreshed, for a statusline or a test
---@return { running: boolean, buffers: table<integer, octo.AutoRefreshEntry> }
function M.status()
  return { running = timer ~= nil, buffers = watched }
end

return M
