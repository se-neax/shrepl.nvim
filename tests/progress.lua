-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/progress.lua
local shrepl = require('shrepl')
local api = vim.api
local ns = api.nvim_get_namespaces().shrepl

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, {
  'for i in 1 2 3 4; do echo "step $i"; sleep 0.5; done',
  'echo next',
})
local function mark_at(row)
  local m = api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })[1]
  return m and m[4].virt_text[1][1] or ''
end

shrepl.eval(buf, 0, 0); shrepl.eval(buf, 1, 1)
assert(mark_at(0) == '… running', 'head starts as running')
assert(mark_at(1) == '… queued', 'second eval waits as queued')

assert(vim.wait(3000, function() return mark_at(0):match('^… %ds · step %d$') ~= nil end, 20),
  'running mark shows elapsed seconds and the latest output line, got ' .. mark_at(0))
assert(mark_at(1) == '… queued', 'still queued while the first runs')

assert(vim.wait(5000, function() return mark_at(0) == '=> step 1  …+3' end, 20), 'final result replaces progress')
assert(vim.wait(3000, function() return mark_at(1) == '=> next' end, 20), 'queued eval runs after')
vim.wait(1200)
assert(mark_at(1) == '=> next', 'ticker leaves finished marks alone')

print('ok')
vim.cmd('qa!')
