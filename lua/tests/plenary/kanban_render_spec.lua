---@diagnostic disable
local render = require "octo.kanban.render"

local function card(number, title, labels)
  return {
    number = number,
    title = title,
    state = "OPEN",
    labels = labels or {},
    is_pr = false,
    repo = "acme/widgets",
  }
end

local function column(name, cards, option_id)
  return { name = name, option_id = option_id or ("opt_" .. name), cards = cards or {} }
end

--- Narrow columns keep the assertions readable.
local OPTS = { width = 30, gap = 2 }

--- The text of one column on a line. Character-based, not byte-based: box-drawing
--- characters are multibyte, so string.sub would cut a rule line a third of the way in.
local function slice(lines, index, opts)
  opts = opts or OPTS
  local from = (index - 1) * (opts.width + opts.gap)
  return vim.trim(vim.fn.strcharpart(lines, from, opts.width))
end

describe("kanban render", function()
  describe("headers", function()
    it("names each column and counts its cards", function()
      local out = render.layout({ column("Todo", { card(1, "a"), card(2, "b") }) }, OPTS)
      assert.are.equal("Todo (2)", slice(out.lines[1], 1))
    end)

    it("underlines the header across the column width", function()
      local out = render.layout({ column("Todo") }, OPTS)
      assert.are.equal(string.rep("─", OPTS.width), slice(out.lines[2], 1))
    end)

    it("renders an empty column as nothing but its header", function()
      local out = render.layout({ column("Todo"), column("Doing", { card(1, "a") }) }, OPTS)
      assert.are.equal("Todo (0)", slice(out.lines[1], 1))
      assert.are.equal("", slice(out.lines[3], 1))
    end)
  end)

  describe("columns side by side", function()
    it("places each column at a fixed horizontal offset", function()
      local out = render.layout({ column("Todo", { card(1, "first") }), column("Doing", { card(2, "second") }) }, OPTS)
      assert.are.equal("Todo (1)", slice(out.lines[1], 1))
      assert.are.equal("Doing (1)", slice(out.lines[1], 2))
    end)

    it("pads every line to the full board width so scrolling does not jitter", function()
      local out = render.layout({ column("Todo", { card(1, "a") }), column("Doing") }, OPTS)
      local expected = 2 * OPTS.width + OPTS.gap
      for _, line in ipairs(out.lines) do
        assert.are.equal(expected, vim.fn.strdisplaywidth(line))
      end
    end)

    it("reports where each column starts", function()
      local out = render.layout({ column("Todo"), column("Doing"), column("Done") }, OPTS)
      assert.are.same({ 0, 32, 64 }, out.column_x)
    end)
  end)

  describe("cards", function()
    it("puts the number and the start of the title on the first line", function()
      local out = render.layout({ column("Todo", { card(101, "Fix the thing") }) }, OPTS)
      assert.are.equal("#101  Fix the thing", slice(out.lines[3], 1))
    end)

    it("wraps a long title underneath, aligned past the number", function()
      local out = render.layout({ column("Todo", { card(101, "Plan the production migration") }) }, OPTS)
      assert.are.equal("#101  Plan the production", slice(out.lines[3], 1))
      assert.are.equal("migration", slice(out.lines[4], 1))
      -- the continuation is indented to sit under the title, not the number
      assert.is_truthy(string.match(out.lines[4], "^      migration"))
    end)

    it("truncates a title too long for two lines", function()
      local long = "Reconcile incoming sonogram results to originating orders across every clinic"
      local out = render.layout({ column("Todo", { card(101, long) }) }, OPTS)
      assert.is_truthy(string.match(out.lines[4], "…"))
      -- nothing spills past the two title lines into a third
      assert.are.equal("", slice(out.lines[5], 1))
    end)

    it("lists labels beneath the title", function()
      local out = render.layout({ column("Todo", { card(101, "Fix it", { "bug", "p1" }) }) }, OPTS)
      assert.are.equal("bug  p1", slice(out.lines[4], 1))
    end)

    it("omits the label line when a card has none", function()
      local out = render.layout({ column("Todo", { card(101, "Fix it"), card(102, "Other") }) }, OPTS)
      assert.are.equal("#101  Fix it", slice(out.lines[3], 1))
      assert.are.equal("", slice(out.lines[4], 1))
      assert.are.equal("#102  Other", slice(out.lines[5], 1))
    end)

    it("separates cards with a blank line", function()
      local out = render.layout({ column("Todo", { card(1, "a"), card(2, "b") }) }, OPTS)
      assert.are.equal("#1  a", slice(out.lines[3], 1))
      assert.are.equal("", slice(out.lines[4], 1))
      assert.are.equal("#2  b", slice(out.lines[5], 1))
    end)
  end)

  describe("finding the card under the cursor", function()
    it("maps a position inside a card back to it", function()
      local out = render.layout({ column("Todo", { card(101, "a") }), column("Doing", { card(202, "b") }) }, OPTS)
      assert.are.equal(101, render.card_at(out, 3, 2).card.number)
      assert.are.equal(202, render.card_at(out, 3, 34).card.number)
    end)

    it("maps every line a wrapped card occupies", function()
      local out = render.layout({ column("Todo", { card(101, "Plan the production migration") }) }, OPTS)
      assert.are.equal(101, render.card_at(out, 3, 2).card.number)
      assert.are.equal(101, render.card_at(out, 4, 2).card.number)
    end)

    it("returns nothing for a blank position", function()
      local out = render.layout({ column("Todo", { card(101, "a") }) }, OPTS)
      assert.is_nil(render.card_at(out, 1, 2))
      assert.is_nil(render.card_at(out, 99, 2))
    end)

    it("reports which column a position belongs to", function()
      local out = render.layout({ column("Todo", { card(101, "a") }), column("Doing", { card(202, "b") }) }, OPTS)
      assert.are.equal(2, render.card_at(out, 3, 34).column_index)
    end)
  end)

  describe("keeping the focused column in view", function()
    -- a window showing 100 columns of a board whose columns are 30 wide
    local WIN = 100

    it("does not scroll when the column is already fully visible", function()
      assert.is_nil(render.scroll_to(0, WIN, 0, 30))
      assert.is_nil(render.scroll_to(0, WIN, 64, 30))
    end)

    it("scrolls right just far enough to reveal the whole column", function()
      -- column at 96..126 overflows a window showing 0..100
      assert.are.equal(26, render.scroll_to(0, WIN, 96, 30))
    end)

    it("scrolls left to the column when it sits off the left edge", function()
      assert.are.equal(32, render.scroll_to(64, WIN, 32, 30))
    end)

    it("never scrolls past the start of the board", function()
      assert.are.equal(0, render.scroll_to(10, WIN, 0, 30))
    end)

    it("shows the left edge of a column wider than the window", function()
      assert.are.equal(96, render.scroll_to(0, 20, 96, 30))
    end)
  end)

  describe("the key reference", function()
    it("lists every binding with what it does", function()
      local help = render.help()
      local joined = table.concat(help, "\n")
      for _, key in ipairs { "h", "l", "j", "k", "<CR>", "<", ">", "r", "q", "?" } do
        assert.is_truthy(joined:find(key, 1, true), "missing key: " .. key)
      end
      assert.is_truthy(joined:find("zH", 1, true))
    end)
  end)
end)
