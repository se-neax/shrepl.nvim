-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/shells.lua
local shrepl = require('shrepl')
local api = vim.api
local ns = api.nvim_get_namespaces().shrepl

local home = vim.fn.tempname()
vim.fn.mkdir(home, 'p')
vim.fn.writefile({ "alias hi='echo hello from rc'", 'greet() { echo "hi $1"; }' }, home .. '/.bashrc')
vim.fn.writefile({ "alias hi='echo hello from zshrc'" }, home .. '/.zshrc')

local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
local function result(cmd)
  api.nvim_buf_set_lines(buf, 0, -1, false, { cmd })
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  shrepl.eval(buf, 0, 0)
  local text
  assert(vim.wait(5000, function()
    local m = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
    text = m and m[4].virt_text[1][1]
    return text and text ~= '… running'
  end, 20), 'timeout: ' .. cmd)
  return text
end
local function use(opts)
  shrepl.restart(); vim.wait(200)
  shrepl.setup(vim.tbl_extend('force', { env = { HOME = home, ZDOTDIR = home, PAGER = 'cat' } }, opts))
end
local function eq(want, got, what) assert(want == got, ('%s: want %q, got %q'):format(what, want, got)) end

use({ shell = 'bash' })
eq('=> bash', result('[ -n "$BASH_VERSION" ] && echo bash'), 'default bash')
assert(result('hi'):match('^✗'), 'no rc by default: alias unknown')

use({ shell = 'bash', rc = true })
eq('=> hello from rc', result('hi'), 'bash rc aliases')
eq('=> hi you', result('greet you'), 'bash rc functions')

use({ shell = { 'bash', '--norc', '--noprofile' } })
eq('=> ok', result('echo ok'), 'argv list still works')

if vim.fn.executable('zsh') == 1 then
  use({ shell = 'zsh' })
  eq('=> zsh', result('[ -n "$ZSH_VERSION" ] && echo zsh'), 'zsh')
  eq('=> 3', result('X=1; X=$((X+2)); echo $X'), 'zsh state within an eval')
  eq('=> 3', result('echo $X'), 'zsh state persists')
  use({ shell = 'zsh', rc = true })
  eq('=> hello from zshrc', result('hi'), 'zsh rc aliases')
  vim.env.SHELL = '/usr/bin/zsh'
  use({ shell = 'auto' })
  eq('=> zsh', result('[ -n "$ZSH_VERSION" ] && echo zsh'), 'auto picks $SHELL')
else
  print('zsh not installed, skipping zsh cases')
end
vim.env.SHELL = '/bin/fish'
use({ shell = 'auto' })
eq('=> bash', result('[ -n "$BASH_VERSION" ] && echo bash'), 'auto falls back to bash')

print('ok')
vim.cmd('qa!')
