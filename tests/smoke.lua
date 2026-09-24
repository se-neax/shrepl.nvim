-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/smoke.lua
local shrepl = require('shrepl')
local api = vim.api
local ns = api.nvim_get_namespaces().shrepl

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, {
  'X=42',                 -- 1: state
  'echo "x is $X"',       -- 2: state persists
  'printf "a\\nb\\nc\\n"', -- 3: multi-line
  'echo one \\',          -- 4: continuation
  '  two',                -- 5
  'false',                -- 6: exit code
  'echo "unterminated',   -- 7: syntax error must not wedge the shell
  'echo "alive $X"',      -- 8
  'sleep 30',             -- 9: interrupted
  'echo "after $X"',      -- 10
})

local function mark_at(row)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[2] == row then return m[4].virt_text[1][1] end
  end
end
local function eval_cursor(row, range)
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  shrepl.eval(buf, shrepl.ranges[range or 'command']())
end
local function wait_for(row)
  assert(vim.wait(5000, function() local t = mark_at(row); return t and t ~= '… running' end, 20), 'timeout on row ' .. row)
  return mark_at(row)
end
local function eq(want, got, what) assert(got == want, ('%s: want %q, got %q'):format(what, want, got)) end

eval_cursor(0); eval_cursor(1); eval_cursor(2); eval_cursor(3); eval_cursor(5); eval_cursor(6); eval_cursor(7)
eq('=> ', wait_for(0), 'assignment')
eq('=> x is 42', wait_for(1), 'state persists')
eq('=> a  …+2', wait_for(2), 'multi-line summary')
local floats = vim.tbl_filter(function(w) return api.nvim_win_get_config(w).relative ~= '' end, api.nvim_list_wins())
assert(#floats > 0, 'multi-line output opens a float')
eq('=> one two', wait_for(4), 'continuation runs as one command, result on last line')
eq('✗ 1  ', wait_for(5), 'non-zero exit')
assert(wait_for(6):match('^✗ 2 '), 'syntax error reported')
eq('=> alive 42', wait_for(7), 'shell survives syntax error')

eval_cursor(8); vim.wait(300); shrepl.interrupt()
eq('✗ 130  ', wait_for(8), 'interrupt')
eval_cursor(9)
eq('=> after 42', wait_for(9), 'state survives interrupt')

shrepl.open_last()
eq('after 42', api.nvim_buf_get_lines(0, 0, 1, false)[1], 'open_last shows last result')

local log = api.nvim_buf_get_lines(vim.fn.bufnr('shrepl-log'), 0, -1, false)
local i = vim.fn.index(log, 'echo "x is $X"')
eq('x is 42', log[i + 2], 'log keeps code followed by its own output')

print('ok')
vim.cmd('qa!')
