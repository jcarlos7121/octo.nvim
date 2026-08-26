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
  local worktrees
  local relation_revs
  local relation_pairs
  local real_branch_relation
  local real_branches_related_to

  -- a stack of three layers, each cut from the one below it
  local stack = {
    ["origin/feature_a_part_2"] = {
      feature_a = { kind = "ancestor", distance = 2 },
      feature_a_part_3 = { kind = "descendant", distance = 3 },
      landed_feature = { kind = "ancestor", distance = 40 },
      master = { kind = "ancestor", distance = 7 },
    },
  }

  before_each(function()
    checkout_opts = nil
    switched_to = nil
    confirm_answer = 1
    confirm_prompts = {}
    relation_revs = {}
    relation_pairs = {}
    -- a worktree per feature: the trunk, the layer below, and an unrelated one
    worktrees = {
      { path = "/repos/main", branch = "master" },
      { path = "/repos/wt-feature-a", branch = "feature_a" },
      { path = "/repos/wt-other", branch = "other_feature" },
    }

    utils = require "octo.utils"
    gh = require "octo.gh"

    gh.pr = {
      checkout = function(opts)
        checkout_opts = opts
      end,
    }

    utils.info = function() end
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
    -- the PR's branch only exists on the remote until it is checked out
    utils.resolve_branch_rev = function(branch)
      if branch == nil then
        return nil
      end
      if branch == "feature_a_part_2" then
        return "origin/feature_a_part_2"
      end
      return branch
    end
    real_branch_relation = utils.branch_relation
    utils.branch_relation = function(rev, other)
      table.insert(relation_revs, rev)
      table.insert(relation_pairs, other)
      return (stack[rev] or {})[other]
    end
    real_branches_related_to = utils.branches_related_to
    utils.branches_related_to = function(rev)
      local descendants, ancestors = {}, {}
      for branch, relation in pairs(stack[rev] or {}) do
        if relation.kind == "descendant" then
          descendants[branch] = true
        else
          ancestors[branch] = true
        end
      end
      return { descendants = descendants, ancestors = ancestors }
    end
    utils.branch_contained_in = function(branch)
      return branch == "landed_feature"
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

    it("falls back to the closest layer when no worktree holds the base", function()
      table.insert(worktrees, { path = "/repos/wt-part-3", branch = "feature_a_part_3" })
      local worktree = utils.worktree_for_related_branch("feature_a_part_2", "feature_a_part_1")
      -- the layer below is 2 commits away, the one stacked on top 3
      eq("/repos/wt-feature-a", worktree.path)
    end)

    it("finds a worktree holding a branch stacked on top of the PR's branch", function()
      -- the shape that used to fall through: nothing below the branch is checked
      -- out, but the layer above it sits in the feature's worktree
      worktrees = {
        { path = "/repos/main", branch = "master" },
        { path = "/repos/wt-part-3", branch = "feature_a_part_3" },
      }
      local worktree = utils.worktree_for_related_branch("feature_a_part_2", "master")
      eq("/repos/wt-part-3", worktree.path)
      eq("feature_a_part_3", worktree.branch)
    end)

    it("compares against the remote ref while the branch is not local", function()
      utils.worktree_for_related_branch("feature_a_part_2", "no_such_base")
      assert.is_true(#relation_revs > 0)
      for _, rev in ipairs(relation_revs) do
        eq("origin/feature_a_part_2", rev)
      end
    end)

    it("measures only the branches git reports as related", function()
      utils.worktree_for_related_branch("feature_a_part_2", "no_such_base")
      -- other_feature is in neither set, so it never costs a git call
      eq({ "feature_a" }, relation_pairs)
    end)

    it("measures every branch when git cannot answer", function()
      utils.branches_related_to = function()
        return nil
      end
      utils.worktree_for_related_branch("feature_a_part_2", "no_such_base")
      eq({ "feature_a", "other_feature" }, relation_pairs)
    end)

    it("ignores a worktree branch that already landed on the trunk", function()
      worktrees = {
        { path = "/repos/main", branch = "master" },
        { path = "/repos/wt-landed", branch = "landed_feature" },
      }
      -- an ancestor only because the PR branch was cut after it merged
      eq(nil, utils.worktree_for_related_branch("feature_a_part_2", "master"))
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

  describe("branch_relation", function()
    local original_system

    before_each(function()
      original_system = vim.system
    end)

    after_each(function()
      vim.system = original_system
    end)

    ---@param code integer
    ---@param stdout string
    local function git_returns(code, stdout)
      vim.system = function()
        return {
          wait = function()
            return { code = code, stdout = stdout }
          end,
        }
      end
    end

    it("reads a branch behind the rev as an ancestor", function()
      git_returns(0, "5\t0\n")
      eq({ kind = "ancestor", distance = 5 }, real_branch_relation("origin/feature_a_part_2", "feature_a"))
    end)

    it("reads a branch ahead of the rev as a descendant", function()
      git_returns(0, "0\t8\n")
      eq({ kind = "descendant", distance = 8 }, real_branch_relation("origin/feature_a_part_2", "feature_a_part_3"))
    end)

    it("calls a branch at the same commit an ancestor at distance zero", function()
      git_returns(0, "0\t0\n")
      eq({ kind = "ancestor", distance = 0 }, real_branch_relation("origin/feature_a_part_2", "mirror_branch"))
    end)

    it("has no relation for diverged branches", function()
      git_returns(0, "3\t4\n")
      eq(nil, real_branch_relation("origin/feature_a_part_2", "other_feature"))
    end)

    it("has no relation when git cannot resolve a ref", function()
      git_returns(128, "")
      eq(nil, real_branch_relation("origin/feature_a_part_2", "gone_branch"))
    end)
  end)

  describe("branches_related_to", function()
    local original_system

    before_each(function()
      original_system = vim.system
    end)

    after_each(function()
      vim.system = original_system
    end)

    ---@param answers table<string, {code: integer, stdout: string}>
    local function git_answers(answers)
      vim.system = function(cmd)
        local flag = cmd[4]
        return {
          wait = function()
            return answers[flag] or { code = 128, stdout = "" }
          end,
        }
      end
    end

    it("splits the two listings into sets", function()
      git_answers {
        ["--contains"] = { code = 0, stdout = "feature_a_part_2\nfeature_a_part_3\n" },
        ["--merged"] = { code = 0, stdout = "feature_a\nmaster\n" },
      }
      local related = real_branches_related_to "origin/feature_a_part_2"
      eq(true, related.descendants.feature_a_part_3)
      eq(true, related.ancestors.feature_a)
      eq(true, related.ancestors.master)
      eq(nil, related.descendants.other_feature)
    end)

    it("answers nil when git fails, so no branch is filtered out", function()
      git_answers {
        ["--contains"] = { code = 0, stdout = "feature_a_part_3\n" },
        ["--merged"] = { code = 129, stdout = "" },
      }
      eq(nil, real_branches_related_to "origin/feature_a_part_2")
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

    it("asks before moving the trunk worktree off the default branch", function()
      confirm_answer = 2 -- No
      utils.checkout_pr(99, "unrelated_branch", "no_such_base")

      eq(1, #confirm_prompts)
      assert.is_truthy(confirm_prompts[1]:find("unrelated_branch", 1, true))
      assert.is_truthy(confirm_prompts[1]:find("/repos/main", 1, true))
      eq(nil, checkout_opts) -- nothing was checked out anywhere
      eq(nil, switched_to)
    end)

    it("checks out on the trunk worktree once that is confirmed", function()
      confirm_answer = 1 -- Yes
      utils.checkout_pr(99, "unrelated_branch", "no_such_base")

      eq(1, #confirm_prompts)
      assert.is_not_nil(checkout_opts)
    end)

    it("does not ask in a repository with a single worktree", function()
      worktrees = { { path = "/repos/main", branch = "master" } }
      utils.checkout_pr(99, "unrelated_branch", "no_such_base")

      eq(0, #confirm_prompts)
      assert.is_not_nil(checkout_opts)
    end)

    it("does not ask when the current worktree is not on the default branch", function()
      utils.current_worktree_path = function()
        return "/repos/wt-other"
      end
      utils.checkout_pr(99, "unrelated_branch", "no_such_base")

      eq(0, #confirm_prompts)
      assert.is_not_nil(checkout_opts)
    end)
  end)
end)
