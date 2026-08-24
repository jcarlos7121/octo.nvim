---@diagnostic disable
local eq = assert.are.same

describe("worktree-aware PR checkout:", function()
  local utils
  local gh
  local checkout_opts
  local switched_to
  local info_messages
  local error_messages

  local porcelain = table.concat({
    "worktree /repos/main",
    "HEAD aaaaaaa",
    "branch refs/heads/main",
    "",
    "worktree /repos/wt-one",
    "HEAD bbbbbbb",
    "branch refs/heads/feat-one",
    "",
    "worktree /repos/detached",
    "HEAD ccccccc",
    "detached",
    "",
  }, "\n")

  before_each(function()
    checkout_opts = nil
    switched_to = nil
    info_messages = {}
    error_messages = {}

    utils = require "octo.utils"
    gh = require "octo.gh"

    gh.pr = {
      checkout = function(opts)
        checkout_opts = opts
      end,
    }

    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    utils.error = function(msg)
      table.insert(error_messages, msg)
    end
  end)

  after_each(function()
    package.loaded["octo.utils"] = nil
    package.loaded["octo.gh"] = nil
  end)

  describe("parse_worktrees", function()
    it("parses worktree paths and their branches", function()
      local worktrees = utils.parse_worktrees(porcelain)
      eq(3, #worktrees)
      eq("/repos/main", worktrees[1].path)
      eq("main", worktrees[1].branch)
      eq("/repos/wt-one", worktrees[2].path)
      eq("feat-one", worktrees[2].branch)
      eq("/repos/detached", worktrees[3].path)
      eq(nil, worktrees[3].branch)
    end)

    it("returns an empty list for blank output", function()
      eq({}, utils.parse_worktrees "")
      eq({}, utils.parse_worktrees(nil))
    end)
  end)

  describe("worktree_path_for_branch", function()
    before_each(function()
      utils.get_worktrees = function()
        return utils.parse_worktrees(porcelain)
      end
    end)

    it("finds the worktree holding a branch", function()
      eq("/repos/wt-one", utils.worktree_path_for_branch "feat-one")
    end)

    it("returns nil when no worktree holds the branch", function()
      eq(nil, utils.worktree_path_for_branch "feat-other")
      eq(nil, utils.worktree_path_for_branch(nil))
    end)
  end)

  describe("checkout_pr", function()
    before_each(function()
      utils.get_worktrees = function()
        return utils.parse_worktrees(porcelain)
      end
      utils.switch_to_worktree = function(path)
        switched_to = path
        return true
      end
      utils.current_worktree_path = function()
        return "/repos/main"
      end
    end)

    it("switches to the worktree that already holds the PR branch", function()
      utils.checkout_pr(42, "feat-one")
      eq("/repos/wt-one", switched_to)
      eq(nil, checkout_opts)
    end)

    it("checks out normally when no worktree holds the branch", function()
      utils.checkout_pr(42, "feat-other")
      eq(nil, switched_to)
      assert.is_not_nil(checkout_opts)
      eq(42, checkout_opts[1])
    end)

    it("checks out normally when the branch belongs to the current worktree", function()
      utils.checkout_pr(42, "main")
      eq(nil, switched_to)
      assert.is_not_nil(checkout_opts)
    end)

    it("checks out normally when the head branch is unknown", function()
      utils.checkout_pr(42)
      eq(nil, switched_to)
      assert.is_not_nil(checkout_opts)
    end)

    it("switches to the worktree named in a failed checkout", function()
      utils.checkout_pr(42, "feat-other")
      checkout_opts.opts.cb("", "fatal: 'feat-one' is already used by worktree at '/repos/wt-one'", 1)
      eq("/repos/wt-one", switched_to)
      eq(0, #error_messages)
    end)

    it("handles the 'already checked out at' wording", function()
      utils.checkout_pr(42, "feat-other")
      checkout_opts.opts.cb("", "fatal: 'feat-one' is already checked out at '/repos/wt-one'", 1)
      eq("/repos/wt-one", switched_to)
    end)

    it("resolves the worktree by branch name when the path is absent", function()
      utils.checkout_pr(42, "feat-other")
      checkout_opts.opts.cb("", "fatal: 'feat-one' is already used by a worktree", 1)
      eq("/repos/wt-one", switched_to)
    end)

    it("reports unrelated checkout failures", function()
      utils.checkout_pr(42, "feat-other")
      checkout_opts.opts.cb("", "fatal: could not fetch the pull request", 1)
      eq(nil, switched_to)
      eq(1, #error_messages)
      assert.is_truthy(error_messages[1]:find("could not fetch", 1, true))
    end)
  end)

  describe("switch_to_worktree", function()
    it("changes the working directory and reports it", function()
      local original = vim.fn.getcwd()
      local target = vim.fn.tempname()
      vim.fn.mkdir(target, "p")

      eq(true, utils.switch_to_worktree(target))
      eq(vim.fn.resolve(target), vim.fn.resolve(vim.fn.getcwd()))
      eq(1, #info_messages)
      assert.is_truthy(info_messages[1]:find("worktree", 1, true))

      vim.cmd.cd(original)
      vim.fn.delete(target, "d")
    end)

    it("keeps the working directory when the worktree is gone", function()
      local original = vim.fn.getcwd()
      eq(false, utils.switch_to_worktree "/definitely/not/a/worktree")
      eq(original, vim.fn.getcwd())
      eq(1, #error_messages)
    end)
  end)
end)
