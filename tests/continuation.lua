-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/continuation.lua
local shrepl = require('shrepl')
local api = vim.api

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, {
  'echo a',             -- 0
  'curl -s x |',        -- 1  pipe
  '  jq .name |',       -- 2  pipe
  '  head -1',          -- 3
  'make build &&',      -- 4  and
  '  make test ||',     -- 5  or
  '  echo failed',      -- 6
  'echo one \\',        -- 7  backslash still works
  '  two',              -- 8
  'echo "a | b"',       -- 9  pipe inside the line, not at the end
  'echo z',             -- 10
  'printf foo \\|',     -- 11 escaped pipe: complete command
  'echo x # a | b |',   -- 12 pipe in a trailing comment
  '# note ending in |', -- 13 comment line
  'echo after',         -- 14
})

for _, c in ipairs({
  { row = 0, want = { 0, 0 } },
  { row = 1, want = { 1, 3 } }, { row = 2, want = { 1, 3 } }, { row = 3, want = { 1, 3 } },
  { row = 4, want = { 4, 6 } }, { row = 6, want = { 4, 6 } },
  { row = 7, want = { 7, 8 } }, { row = 8, want = { 7, 8 } },
  { row = 9, want = { 9, 9 } }, { row = 10, want = { 10, 10 } },
  { row = 11, want = { 11, 11 } }, { row = 12, want = { 12, 12 } }, { row = 14, want = { 14, 14 } },
}) do
  api.nvim_win_set_cursor(0, { c.row + 1, 0 })
  local got = { shrepl.ranges.command() }
  assert(vim.deep_equal(c.want, got), ('row %d: want %s, got %s'):format(c.row, vim.inspect(c.want), vim.inspect(got)))
end

api.nvim_buf_set_lines(buf, 0, -1, false, { 'printf "x\\ny\\n" |', '  tail -1' })
api.nvim_win_set_cursor(0, { 1, 0 })
shrepl.eval(buf, shrepl.ranges.command())
local ns = api.nvim_get_namespaces().shrepl
assert(vim.wait(5000, function()
  local m = api.nvim_buf_get_extmarks(buf, ns, { 1, 0 }, { 1, -1 }, { details = true })[1]
  return m and m[4].virt_text[1][1] == '=> y'
end, 20), 'pipe-continued command runs as one')

print('ok')
vim.cmd('qa!')
