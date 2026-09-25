-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/signs.lua
local shrepl = require('shrepl')
local api = vim.api
local sns = api.nvim_get_namespaces().shrepl_signs

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, { 'echo ok', 'false', 'echo a \\', '  b', 'sleep 1' })

local function signs()
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, sns, 0, -1, { details = true })) do
    out[m[2]] = vim.trim(m[4].sign_text)
  end
  return out
end
local function wait_sign(row, want)
  assert(vim.wait(5000, function() return signs()[row] == want end, 20),
    ('row %d: want %s, got %s'):format(row, want, tostring(signs()[row])))
end

shrepl.eval(buf, 0, 0); shrepl.eval(buf, 1, 1); shrepl.eval(buf, 2, 3)
wait_sign(0, '✓'); wait_sign(1, '✗'); wait_sign(2, '✓'); wait_sign(3, '✓')

shrepl.eval(buf, 4, 4)
assert(signs()[4] == '·', 'running sign while the command runs')
wait_sign(4, '✓')

-- re-running a line while its earlier eval is queued: the older one must not win
api.nvim_buf_set_lines(buf, 4, 5, false, { 'sleep 0.4' })
shrepl.eval(buf, 4, 4); shrepl.eval(buf, 4, 4)
vim.wait(600)
assert(signs()[4] == '·', 'first run finishing does not mark the second as done')
wait_sign(4, '✓')
local marks = api.nvim_buf_get_extmarks(buf, sns, { 4, 0 }, { 4, -1 }, {})
assert(#marks == 1, 'one sign per line, not a duplicate')

shrepl.clear()
assert(signs()[0] == '✓', 'clear() keeps the signs')
api.nvim_buf_set_lines(buf, 0, 0, false, { '# inserted above' })
assert(signs()[1] == '✓', 'signs move with their lines')
shrepl.clear(true)
assert(next(signs()) == nil, 'clear(true) removes signs')

shrepl.setup({ signs = false })
shrepl.eval(buf, 1, 1)
vim.wait(300)
assert(next(signs()) == nil, 'signs = false turns them off')

print('ok')
vim.cmd('qa!')
