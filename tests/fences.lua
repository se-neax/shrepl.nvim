-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/fences.lua
local shrepl = require('shrepl')
local api = vim.api

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, {
  '# Runbook',                --  0
  '```sh',                    --  1
  'A=1',                      --  2
  '',                         --  3  blank line inside the fence
  'echo "a=$A"',              --  4
  '```',                      --  5
  'prose between blocks',     --  6
  '```python',                --  7
  'print("no")',              --  8
  '```',                      --  9
  '',                         -- 10
  'X=2',                      -- 11  outside any fence
  'echo "x=$X"',              -- 12
  '~~~python',                -- 13  tilde fence, not shell
  'print("no")',              -- 14
  '~~~',                      -- 15
  '~~~ bash',                 -- 16  tilde fence, shell
  'echo "~~~ is not a closer here"', -- 17
  '````',                     -- 18  4 backticks: longer than 3, but different char → still inside
  '~~~~',                     -- 19  closer (tilde, ≥ 3)
  '```',                      -- 20  unclosed, no language
  'echo "tail $A$X"',         -- 21
})
vim.notify = function() return { id = 1 } end -- nvim-notify style: returns a handle

local function range_at(row)
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  local s, e = shrepl.ranges.block()
  return s and { s, e } or {}
end
local function eq(want, got, what)
  assert(vim.deep_equal(want, got), ('%s: want %s, got %s'):format(what, vim.inspect(want), vim.inspect(got)))
end

for _, case in ipairs({
  { row = 2, want = { 2, 4 }, what = 'inside sh fence: whole body, across blank line' },
  { row = 4, want = { 2, 4 }, what = 'last body line' },
  { row = 1, want = { 2, 4 }, what = 'on the opening fence line' },
  { row = 6, want = { 6, 6 }, what = 'prose between fences: plain block' },
  { row = 8, want = {}, what = 'python fence is refused' },
  { row = 11, want = { 11, 12 }, what = 'outside fences: block stops at the next fence' },
  { row = 5, want = { 2, 4 }, what = 'on the closing fence line' },
  { row = 9, want = {}, what = 'closing line of the python fence is refused too' },
  { row = 14, want = {}, what = 'tilde python fence is refused' },
  { row = 17, want = { 17, 18 }, what = 'tilde bash fence; a backtick line does not close it' },
  { row = 21, want = { 21, 21 }, what = 'unclosed fence runs to end of buffer' },
}) do eq(case.want, range_at(case.row), case.what) end

for info, want in pairs({ ['{python}'] = {}, ['{.bash}'] = { 1, 1 }, ['{bash}'] = { 1, 1 }, ['#!'] = {} }) do
  local b = api.nvim_create_buf(false, true)
  api.nvim_set_current_buf(b)
  api.nvim_buf_set_lines(b, 0, -1, false, { '```' .. info, 'echo x', '```' })
  eq(want, range_at(1), 'info string ' .. info)
end
-- fence indented under a list item: the heredoc terminator must reach bash unindented
local lb = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(lb)
api.nvim_buf_set_lines(lb, 0, -1, false, { '1. step', '   ```sh', '   cat <<EOF', '   hi', '   EOF', '   ```' })
api.nvim_win_set_cursor(0, { 3, 0 })
shrepl.eval(lb, shrepl.ranges.block())
local ns = api.nvim_get_namespaces().shrepl
assert(vim.wait(5000, function()
  local m = api.nvim_buf_get_extmarks(lb, ns, { 4, 0 }, { 4, -1 }, { details = true })[1]
  return m and m[4].virt_text[1][1] == '=> hi'
end, 20), 'indented fence is dedented (heredoc closes)')
api.nvim_set_current_buf(buf)

api.nvim_win_set_cursor(0, { 3, 0 })
shrepl.eval(buf, shrepl.ranges.block())
assert(vim.wait(5000, function()
  local m = api.nvim_buf_get_extmarks(buf, ns, { 4, 0 }, { 4, -1 }, { details = true })[1]
  return m and m[4].virt_text[1][1] == '=> a=1'
end, 20), 'fence body evaluated as one unit')

print('ok')
vim.cmd('qa!')
