---@diagnostic disable
local render = require "octo.kanban.render"

local function card(number, title, labels, opts)
  opts = opts or {}
  return {
    number = number,
    title = title,
    state = opts.state or "OPEN",
    labels = labels or {},
    is_pr = opts.pr or false,
    repo = opts.repo or "acme/widgets",
  }
end

local function label(name, color)
  return { name = name, color = color or "d73a4a" }
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

--- Highlight spans on a line, left to right.
local function spans(out, line)
  local found = {}
  for _, hl in ipairs(out.highlights) do
    if hl.line == line then
      found[#found + 1] = hl
    end
  end
  table.sort(found, function(a, b)
    return a.col_start < b.col_start
  end)
  return found
end

describe("kanban render", function()
  describe("headers", function()
    it("names each column and counts its cards", function()
      local out = render.layout({ column("Todo", { card(1, "a"), card(2, "b") }) }, OPTS)
      local header = slice(out.lines[1], 1)
      assert.is_truthy(header:find("Todo", 1, true))
      assert.is_truthy(header:find("2", 1, true))
    end)

    it("underlines the header across the column width", function()
      local out = render.layout({ column "Todo" }, OPTS)
      assert.are.equal(string.rep("─", OPTS.width), slice(out.lines[2], 1))
    end)

    it("renders an empty column as nothing but its header", function()
      local out = render.layout({ column "Todo", column("Doing", { card(1, "a") }) }, OPTS)
      assert.is_truthy(slice(out.lines[1], 1):find("Todo", 1, true))
      assert.are.equal("", slice(out.lines[3], 1))
    end)
  end)

  describe("column status badge", function()
    it("marks a column with a dot in its own status colour", function()
      local col = column("Queue", { card(1, "a") })
      col.color = "BLUE"
      local out = render.layout({ col }, OPTS)
      local head = spans(out, 1)
      -- the dot comes first and is not one of the board's own groups
      assert.is_false(head[1].hl_group:match "^OctoKanban" ~= nil)
      assert.are.equal(0, head[1].col_start)
    end)

    it("still names the column and counts it", function()
      local col = column("Queue", { card(1, "a"), card(2, "b") })
      col.color = "BLUE"
      local out = render.layout({ col }, OPTS)
      assert.is_truthy(out.lines[1]:find("Queue", 1, true))
      assert.is_truthy(out.lines[1]:find("2", 1, true))
    end)

    it("manages without a colour", function()
      local out = render.layout({ column("No Status", { card(1, "a") }) }, OPTS)
      assert.is_truthy(out.lines[1]:find("No Status", 1, true))
    end)

    it("keeps the header inside the column width", function()
      local col = column("An extremely long status name that will not fit", {})
      col.color = "PURPLE"
      local out = render.layout({ col, column "Next" }, OPTS)
      assert.are.equal(2 * OPTS.width + OPTS.gap, vim.fn.strdisplaywidth(out.lines[1]))
    end)
  end)

  describe("columns side by side", function()
    it("places each column at a fixed horizontal offset", function()
      local out = render.layout({ column("Todo", { card(1, "first") }), column("Doing", { card(2, "second") }) }, OPTS)
      assert.is_truthy(slice(out.lines[1], 1):find("Todo", 1, true))
      assert.is_truthy(slice(out.lines[1], 2):find("Doing", 1, true))
    end)

    it("pads every line to the full board width so scrolling does not jitter", function()
      local out = render.layout({ column("Todo", { card(1, "a") }), column "Doing" }, OPTS)
      local expected = 2 * OPTS.width + OPTS.gap
      for _, line in ipairs(out.lines) do
        assert.are.equal(expected, vim.fn.strdisplaywidth(line))
      end
    end)

    it("reports where each column starts", function()
      local out = render.layout({ column "Todo", column "Doing", column "Done" }, OPTS)
      assert.are.same({ 0, 32, 64 }, out.column_x)
    end)
  end)

  describe("cards", function()
    it("heads a card with its state icon and number", function()
      local out = render.layout({ column("Todo", { card(101, "Fix the thing") }) }, OPTS)
      assert.are.equal("⚐ #101", slice(out.lines[3], 1))
    end)

    it("gives the title the whole column, not the space left beside a number", function()
      local out = render.layout({ column("Todo", { card(101, "Fix the thing") }) }, OPTS)
      assert.are.equal("Fix the thing", slice(out.lines[4], 1))
    end)

    it("wraps a long title across the full width", function()
      local out = render.layout({ column("Todo", { card(101, "Plan the production migration now") }) }, OPTS)
      assert.are.equal("Plan the production migration", slice(out.lines[4], 1))
      assert.are.equal("now", slice(out.lines[5], 1))
    end)

    it("truncates a title too long for two lines", function()
      local long = "Reconcile incoming sonogram results to originating orders across every clinic"
      local out = render.layout({ column("Todo", { card(101, long) }) }, OPTS)
      assert.is_truthy(string.match(out.lines[5], "…"))
    end)

    it("names the repository only when the board spans more than one", function()
      local one = render.layout({ column("Todo", { card(101, "a") }) }, OPTS)
      assert.are.equal("⚐ #101", slice(one.lines[3], 1))

      local many = render.layout({
        column("Todo", { card(101, "a"), card(102, "b", nil, { repo = "acme/other" }) }),
      }, OPTS)
      assert.are.equal("⚐ acme/widgets #101", slice(many.lines[3], 1))
    end)

    it("separates cards with a blank line", function()
      local out = render.layout({ column("Todo", { card(1, "a"), card(2, "b") }) }, OPTS)
      assert.are.equal("⚐ #1", slice(out.lines[3], 1))
      assert.are.equal("a", slice(out.lines[4], 1))
      assert.are.equal("", slice(out.lines[5], 1))
      assert.are.equal("⚐ #2", slice(out.lines[6], 1))
    end)
  end)

  describe("label badges", function()
    it("renders each label as a bubble", function()
      local out = render.layout({ column("Todo", { card(101, "a", { label "bug" }) }) }, OPTS)
      local line = out.lines[5]
      assert.is_truthy(line:find("bug", 1, true))
      -- the bubble's delimiters come from the configured left/right delimiter
      local conf = require("octo.config").values
      assert.is_truthy(line:find(conf.left_bubble_delimiter, 1, true))
      assert.is_truthy(line:find(conf.right_bubble_delimiter, 1, true))
    end)

    it("colours a badge from the label's own hex", function()
      local out = render.layout({ column("Todo", { card(101, "a", { label("bug", "d73a4a") }) }) }, OPTS)
      local on_labels = spans(out, 5)
      assert.is_true(#on_labels > 0)
      -- a generated group, not one of the board's own
      local generated = false
      for _, hl in ipairs(on_labels) do
        if not hl.hl_group:match "^OctoKanban" then
          generated = true
        end
      end
      assert.is_true(generated)
    end)

    it("wraps badges onto another line rather than overflowing the column", function()
      local many = { label "documentation", label "enhancement", label "customer" }
      local out = render.layout({ column("Todo", { card(101, "a", many) }) }, OPTS)
      for _, line in ipairs(out.lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= OPTS.width * 1 + OPTS.gap)
      end
    end)

    it("shows only so many badges, and says how many it left out", function()
      local many = { label "one", label "two", label "three", label "four", label "five" }
      local out = render.layout({ column("Todo", { card(101, "a", many) }) }, { width = 30, gap = 2, max_labels = 2 })
      local joined = table.concat(out.lines, "\n")
      assert.is_truthy(joined:find("one", 1, true))
      assert.is_truthy(joined:find("two", 1, true))
      assert.is_falsy(joined:find("three", 1, true))
      assert.is_truthy(joined:find("+3", 1, true))
    end)

    it("says nothing about overflow when every badge fits", function()
      local out = render.layout({ column("Todo", { card(101, "a", { label "one" }) }) }, { width = 30, gap = 2, max_labels = 2 })
      assert.is_falsy(table.concat(out.lines, "\n"):find("+", 1, true))
    end)

    it("leaves no label line when a card has none", function()
      local out = render.layout({ column("Todo", { card(101, "a"), card(102, "b") }) }, OPTS)
      assert.are.equal("", slice(out.lines[5], 1))
      assert.are.equal("⚐ #102", slice(out.lines[6], 1))
    end)
  end)

  describe("finding the card under the cursor", function()
    it("maps a position inside a card back to it", function()
      local out = render.layout({ column("Todo", { card(101, "a") }), column("Doing", { card(202, "b") }) }, OPTS)
      assert.are.equal(101, render.card_at(out, 3, 2).card.number)
      assert.are.equal(202, render.card_at(out, 3, 34).card.number)
    end)

    it("maps every line a card occupies, icon and title alike", function()
      local out = render.layout({ column("Todo", { card(101, "Plan the production migration now") }) }, OPTS)
      for _, line in ipairs { 3, 4, 5 } do
        assert.are.equal(101, render.card_at(out, line, 2).card.number)
      end
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

  describe("colour", function()
    it("colours the state icon, never the title", function()
      local out = render.layout({ column("Todo", { card(101, "Fix the thing") }) }, OPTS)
      assert.is_true(#spans(out, 3) > 0) -- the icon line
      assert.are.equal(0, #spans(out, 4)) -- the title line
    end)

    it("uses the board's own groups, so a colourscheme can override them", function()
      local out = render.layout({ column("Todo", { card(101, "a") }) }, OPTS)
      local header_groups = {}
      for _, hl in ipairs(spans(out, 1)) do
        header_groups[hl.hl_group] = true
      end
      assert.is_true(header_groups.OctoKanbanHeader, "the column name should use the board's header group")
      assert.are.equal("OctoKanbanRule", spans(out, 2)[1].hl_group)
      assert.are.equal("OctoKanbanNumber", spans(out, 3)[1].hl_group)
    end)

    it("lets a finished card recede instead of shouting", function()
      local out = render.layout({ column("Done", { card(101, "Shipped", nil, { state = "CLOSED" }) }) }, OPTS)
      assert.are.equal("OctoKanbanDone", spans(out, 3)[1].hl_group)
    end)

    it("marks a closed card with a different icon than an open one", function()
      local open = render.layout({ column("Todo", { card(1, "a") }) }, OPTS)
      local closed = render.layout({ column("Done", { card(1, "a", nil, { state = "CLOSED" }) }) }, OPTS)
      assert.are_not.equal(slice(open.lines[3], 1), slice(closed.lines[3], 1))
    end)

    it("covers exactly the label text, in bytes as extmarks expect", function()
      -- bubble delimiters are one cell but three bytes, so a span measured in
      -- display cells lands short and smears the colour across its neighbours
      local out = render.layout({ column("Todo", { card(101, "a", { label("bug", "d73a4a") }) }) }, OPTS)
      local line = out.lines[5]
      local covered = {}
      for _, hl in ipairs(out.highlights) do
        if hl.line == 5 then
          covered[#covered + 1] = line:sub(hl.col_start + 1, hl.col_end)
        end
      end
      assert.is_true(vim.tbl_contains(covered, "bug"), "no span covered exactly 'bug': " .. vim.inspect(covered))
    end)

    it("keeps a later column right when an earlier one holds multibyte text", function()
      local out = render.layout({
        column("Todo", { card(1, "LIS — Investigation and Product Definition") }),
        column("Doing", { card(22, "b") }),
      }, OPTS)
      local line = out.lines[3]
      local second
      for _, hl in ipairs(out.highlights) do
        if hl.line == 3 and hl.col_start > 30 then
          second = line:sub(hl.col_start + 1, hl.col_end)
        end
      end
      assert.is_truthy(second)
      assert.is_truthy(second:find("#22", 1, true), "second column span was " .. vim.inspect(second))
    end)

    it("has a link defined for every board group it emits", function()
      local highlights = require "octo.kanban.highlights"
      local out = render.layout({ column("Todo", { card(101, "a", { label "p1" }) }) }, OPTS)
      for _, hl in ipairs(out.highlights) do
        if hl.hl_group:match "^OctoKanban" then
          assert.is_truthy(highlights.links[hl.hl_group], "no link for " .. hl.hl_group)
        end
      end
    end)
  end)

  describe("keeping the focused column in view", function()
    local WIN = 100

    it("does not scroll when the column is already fully visible", function()
      assert.is_nil(render.scroll_to(0, WIN, 0, 30))
      assert.is_nil(render.scroll_to(0, WIN, 64, 30))
    end)

    it("scrolls right just far enough to reveal the whole column", function()
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
