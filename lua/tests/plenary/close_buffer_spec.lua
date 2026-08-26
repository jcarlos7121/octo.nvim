---@diagnostic disable
local eq = assert.are.same

describe("close_buffer:", function()
  local commands
  local utils
  local original_confirm
  local confirm_answer
  local confirm_prompts

  local function make_buffers()
    -- a named buffer: an unnamed empty one is no place to leave the reader, so
    -- landing_buffer refuses it
    local previous = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(previous, "/tmp/previous.rb")
    -- octo buffers are acwrite, not scratch: 'modified' does not stick on nofile buffers
    local octo_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(previous)
    vim.api.nvim_set_current_buf(octo_buf) -- previous becomes the alternate
    return previous, octo_buf
  end

  before_each(function()
    confirm_answer = 1
    confirm_prompts = {}

    -- octo/init.lua defines this global; specs run standalone do not get it
    _G.octo_buffers = _G.octo_buffers or {}

    commands = require "octo.commands"
    utils = require "octo.utils"

    original_confirm = vim.fn.confirm
    vim.fn.confirm = function(prompt)
      table.insert(confirm_prompts, prompt)
      return confirm_answer
    end
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    package.loaded["octo.commands"] = nil
    package.loaded["octo.utils"] = nil
  end)

  it("closes the buffer and returns to the previous one", function()
    local previous, octo_buf = make_buffers()
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    commands.close_buffer()

    eq(previous, vim.api.nvim_get_current_buf())
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))
    eq(0, #confirm_prompts)

    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("keeps the buffer when unsaved changes are not discarded", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "unsynced comment" })
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end
    confirm_answer = 2 -- "No"

    commands.close_buffer()

    eq(1, #confirm_prompts)
    eq(true, vim.api.nvim_buf_is_valid(octo_buf))
    eq(octo_buf, vim.api.nvim_get_current_buf())

    vim.bo[octo_buf].modified = false
    vim.api.nvim_buf_delete(octo_buf, { force = true })
    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("does not ask when octo itself marked the buffer modified", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "rendered by octo" })
    utils.get_current_buffer = function()
      return {
        bufnr = octo_buf,
        -- octo's own view: nothing the reader typed is unsaved
        titleMetadata = { dirty = false },
        bodyMetadata = { dirty = false },
        commentsMetadata = { { dirty = false } },
        update_metadata = function() end,
      }
    end

    commands.close_buffer()

    eq(0, #confirm_prompts)
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))
    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("asks when a section holds an unsynced edit", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "a comment being written" })
    utils.get_current_buffer = function()
      return {
        bufnr = octo_buf,
        titleMetadata = { dirty = false },
        bodyMetadata = { dirty = false },
        commentsMetadata = { { dirty = true } },
        update_metadata = function() end,
      }
    end
    confirm_answer = 2 -- No

    commands.close_buffer()

    eq(1, #confirm_prompts)
    eq(true, vim.api.nvim_buf_is_valid(octo_buf))

    vim.bo[octo_buf].modified = false
    vim.api.nvim_buf_delete(octo_buf, { force = true })
    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("closes a modified buffer once discarding is confirmed", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "unsynced comment" })
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end
    confirm_answer = 1 -- "Yes"

    commands.close_buffer()

    eq(1, #confirm_prompts)
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))

    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("lands on a real file rather than another Octo buffer", function()
    local file = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file, "/tmp/routes.rb")
    local run_view = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:123:" .. run_view)
    local octo_buf = vim.api.nvim_create_buf(true, false)

    vim.api.nvim_set_current_buf(file)
    vim.api.nvim_set_current_buf(run_view)
    vim.api.nvim_set_current_buf(octo_buf) -- alternate is now the run view
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    commands.close_buffer()

    eq(file, vim.api.nvim_get_current_buf())
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))

    vim.api.nvim_buf_delete(run_view, { force = true })
    vim.api.nvim_buf_delete(file, { force = true })
  end)

  it("does not land on a picker buffer left behind by the PR list", function()
    local file = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file, "/tmp/routes.rb")
    local octo_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/9707")
    -- telescope leaves its prompt and preview buffers unlisted and unnamed
    local picker = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_set_current_buf(file)
    vim.api.nvim_set_current_buf(picker)
    vim.api.nvim_set_current_buf(octo_buf) -- the picker is now the alternate
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    commands.close_buffer()

    eq(file, vim.api.nvim_get_current_buf())
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))

    pcall(vim.api.nvim_buf_delete, picker, { force = true })
    pcall(vim.api.nvim_buf_delete, file, { force = true })
  end)

  describe("landing_buffer", function()
    it("skips unlisted and empty unnamed buffers", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/models.rb")
      local unlisted = vim.api.nvim_create_buf(false, true)
      local blank = vim.api.nvim_create_buf(true, false) -- listed, no name, no content
      local closing = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(closing, "octo://owner/repo/pull/1")

      vim.api.nvim_set_current_buf(file)
      vim.api.nvim_set_current_buf(blank)
      vim.api.nvim_set_current_buf(unlisted)
      vim.api.nvim_set_current_buf(closing)

      eq(file, utils.landing_buffer(closing))

      for _, b in ipairs { file, unlisted, blank, closing } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("takes a file never visited this session over an empty page", function()
      -- what a session manager leaves behind: listed, named, lastused == 0
      local restored = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(restored, "/tmp/restored.rb")
      local closing = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(closing, "octo://owner/repo/pull/5")
      vim.api.nvim_set_current_buf(closing)

      eq(restored, utils.landing_buffer(closing))

      for _, b in ipairs { restored, closing } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("skips octo-owned buffers and the buffer being closed", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/schema.rb")
      local run_view = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:9:" .. run_view)
      local pr_view = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(pr_view, "octo://owner/repo/pull/7")
      local closing = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(closing, "/tmp/closing.rb")

      vim.api.nvim_set_current_buf(file)
      vim.api.nvim_set_current_buf(run_view)
      vim.api.nvim_set_current_buf(pr_view)
      vim.api.nvim_set_current_buf(closing)

      eq(file, utils.landing_buffer(closing))
      eq(true, utils.is_octo_owned_buffer(run_view))
      eq(true, utils.is_octo_owned_buffer(pr_view))
      eq(false, utils.is_octo_owned_buffer(file))

      for _, b in ipairs { file, run_view, pr_view, closing } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)
  end)

  it("leaves the replacement to vim when nothing is worth landing on", function()
    local octo_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/3")
    vim.api.nvim_set_current_buf(octo_buf)
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    eq(nil, utils.landing_buffer(octo_buf))
    commands.close_buffer()

    -- the octo buffer still goes away: an empty page beats a buffer that is gone
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))
  end)

  describe("origin file", function()
    -- /tmp is a symlink on macOS: vim reports the resolved name
    local path = vim.fn.resolve "/tmp" .. "/octo-origin-spec.rb"

    before_each(function()
      vim.fn.writefile({ "class Routes", "end" }, path)
    end)

    after_each(function()
      vim.fn.delete(path)
      utils.last_visited_file = nil
    end)

    it("remembers the file an octo view is opened over", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, path)
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/11")

      utils.remember_origin_file(octo_buf, utils.origin_file(file))
      eq(path, vim.b[octo_buf].octo_origin_file)

      -- and a second view opened over the first inherits it
      local second = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(second, "octo://owner/repo/pull/12")
      utils.remember_origin_file(second, utils.origin_file(octo_buf))
      eq(path, vim.b[second].octo_origin_file)

      for _, b in ipairs { file, octo_buf, second } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("remembers nothing for scratch buffers and octo views without a file", function()
      local scratch = vim.api.nvim_create_buf(true, true)
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/13")

      eq(nil, utils.origin_file(scratch))
      eq(nil, utils.origin_file(octo_buf))

      for _, b in ipairs { scratch, octo_buf } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("reopens that file when nothing is left to land on", function()
      -- what `bufhidden=delete` leaves behind: the file buffer is long gone
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/14")
      vim.api.nvim_set_current_buf(octo_buf)
      vim.b[octo_buf].octo_origin_file = path
      utils.landing_buffer = function()
        return nil
      end
      utils.get_current_buffer = function()
        return { bufnr = octo_buf }
      end

      commands.close_buffer()

      eq(path, vim.api.nvim_buf_get_name(0))
      eq(false, vim.api.nvim_buf_is_valid(octo_buf))
      pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(path), { force = true })
    end)

    it("remembers the last file visited and ignores everything else", function()
      utils.last_visited_file = nil
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, path)
      utils.remember_visited_file(file)
      eq(path, utils.last_visited_file)

      -- octo views, scratch buffers and unwritten files leave it alone
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/16")
      utils.remember_visited_file(octo_buf)
      local scratch = vim.api.nvim_create_buf(true, true)
      utils.remember_visited_file(scratch)
      local unsaved = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(unsaved, "/tmp/octo-origin-spec-unwritten.rb")
      utils.remember_visited_file(unsaved)
      eq(path, utils.last_visited_file)

      for _, b in ipairs { file, octo_buf, scratch, unsaved } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("falls back to the last file visited when the view recorded none", function()
      -- the real path: octo opens views with `:edit`, so the buffer it replaced
      -- is already gone and only the remembered path is left
      utils.last_visited_file = path
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/17")
      vim.api.nvim_set_current_buf(octo_buf)
      utils.landing_buffer = function()
        return nil
      end
      utils.get_current_buffer = function()
        return { bufnr = octo_buf }
      end

      commands.close_buffer()

      eq(path, vim.api.nvim_buf_get_name(0))
      pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(path), { force = true })
    end)

    it("does not reopen a file that is gone", function()
      local octo_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(octo_buf, "octo://owner/repo/pull/15")
      vim.b[octo_buf].octo_origin_file = "/tmp/octo-origin-spec-missing.rb"

      eq(false, utils.open_origin_file(octo_buf))
      pcall(vim.api.nvim_buf_delete, octo_buf, { force = true })
    end)
  end)

  it("does nothing outside octo buffers", function()
    local other = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(other)
    utils.get_current_buffer = function()
      return nil
    end

    commands.close_buffer()

    eq(other, vim.api.nvim_get_current_buf())
    eq(true, vim.api.nvim_buf_is_valid(other))
    vim.api.nvim_buf_delete(other, { force = true })
  end)
end)
