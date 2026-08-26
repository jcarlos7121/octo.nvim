---@diagnostic disable
local eq = assert.are.same

describe("worktree for a stacked branch:", function()
  local utils
  local gh
  local checkout_opts
  local switched_to
  local original_confirm
  local confirm_answer
  local confirm_prompts

  -- a worktree per feature: the trunk, the feature line, and an unrelated one
  local worktrees = {
    { path = "/repos/main", branch = "master" },
    { path = "/repos/wt-feature-a", branch = "feature_a" },
    { path = "/repos/wt-other", branch = "other_feature" },
  }

  before_each(function()
    checkout_opts = nil
    switched_to = nil
    confirm_answer = 1
    confirm_prompts = {}

    utils = require "octo.utils"
    gh = require "octo.gh"

    gh.pr = {
      checkout = function(opts)
        checkout_opts = opts
      end,
    }

    utils.get_worktrees = function()
      return vim.deepcopy(worktrees)
    end
    utils.current_worktree_path = function()
      return "/repos/main"
    end
    utils.default_branch = function()
      return "master"
    end
    utils.switch_to_worktree = function(path)
      switched_to = path
      return true
    end
    -- feature_a is an ancestor of the stacked branches; master is a further one
    utils.branch_distance = function(ancestor, head)
      if head ~= "feature_a_part_2" then
        return nil
      end
      if ancestor == "feature_a" then
        return 2
      end
      if ancestor == "master" then
        return 7
      end
      return nil
    end

    original_confirm = vim.fn.confirm
    vim.fn.confirm = function(prompt)
      table.insert(confirm_prompts, prompt)
      return confirm_answer
    end
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    package.loaded["octo.utils"] = nil
    package.loaded["octo.gh"] = nil
  end)

  describe("worktree_for_related_branch", function()
    it("prefers the worktree holding the PR's base branch", function()
      local worktree = utils.worktree_for_related_branch("feature_a_part_2", "feature_a")
      eq("/repos/wt-feature-a", worktree.path)
      eq("feature_a", worktree.branch)
    end)

    it("falls back to the closest ancestor when no worktree holds the base", function()
      local worktree = utils.worktree_for_related_branch("feature_a_part_2", "feature_a_part_1")
      eq("/repos/wt-feature-a", worktree.path) -- distance 2, closer than master's 7
    end)

    it("never proposes the current worktree", function()
      utils.current_worktree_path = function()
        return "/repos/wt-feature-a"
      end
      eq(nil, utils.worktree_for_related_branch("feature_a_part_2", "feature_a"))
    end)

    it("never proposes the worktree parked on the default branch", function()
      utils.current_worktree_path = function()
        return "/repos/wt-other"
      end
      -- even when master really is the PR's base branch
      eq(nil, utils.worktree_for_related_branch("bugfix_on_master", "master"))
    end)

    it("returns nil when no worktree is related", function()
      eq(nil, utils.worktree_for_related_branch("unrelated_branch", "master_of_none"))
      eq(nil, utils.worktree_for_related_branch(nil, nil))
    end)
  end)

  describe("checkout_pr", function()
    it("asks, then switches to the feature worktree and checks out there", function()
      confirm_answer = 1 -- Yes
      utils.checkout_pr(99, "feature_a_part_2", "feature_a")

      eq(1, #confirm_prompts)
      assert.is_truthy(confirm_prompts[1]:find("feature_a_part_2", 1, true))
      assert.is_truthy(confirm_prompts[1]:find("/repos/wt-feature-a", 1, true))
      assert.is_truthy(confirm_prompts[1]:find("feature_a", 1, true))
      eq("/repos/wt-feature-a", switched_to)
      assert.is_not_nil(checkout_opts) -- checkout runs in the switched worktree
      eq(99, checkout_opts[1])
    end)

    it("checks out where you are when the switch is declined", function()
      confirm_answer = 2 -- No
      utils.checkout_pr(99, "feature_a_part_2", "feature_a")

      eq(1, #confirm_prompts)
      eq(nil, switched_to)
      assert.is_not_nil(checkout_opts)
    end)

    it("still switches without asking when the branch itself has a worktree", function()
      utils.checkout_pr(99, "feature_a", "master")
      eq(0, #confirm_prompts)
      eq("/repos/wt-feature-a", switched_to)
      eq(nil, checkout_opts)
    end)

    it("does not ask when nothing is related", function()
      utils.checkout_pr(99, "unrelated_branch", "no_such_base")
      eq(0, #confirm_prompts)
      eq(nil, switched_to)
      assert.is_not_nil(checkout_opts)
    end)
  end)
end)
