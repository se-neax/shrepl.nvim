-- nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/env.lua
local shrepl = require('shrepl')
local api = vim.api
local ns = api.nvim_get_namespaces().shrepl

local buf = api.nvim_create_buf(false, true)
local function run(lines)
  api.nvim_set_current_buf(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  shrepl.eval(buf, 0, #lines - 1)
  assert(vim.wait(5000, function()
    local m = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
    return m and not m[4].virt_text[1][1]:match('^…')
  end, 20), 'eval timed out')
end
local function env_view()
  local before = api.nvim_get_current_buf()
  shrepl.show_env()
  assert(vim.wait(5000, function() return api.nvim_get_current_buf() ~= before end, 20), 'env split opened')
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  vim.cmd('close')
  return table.concat(lines, '\n')
end

for _, sh in ipairs({ 'bash', 'zsh' }) do
  if sh == 'bash' or vim.fn.executable('zsh') == 1 then
    shrepl.restart(); vim.wait(200)
    shrepl.setup({ shell = sh, env = { PAGER = 'cat', KEEP_ME = 'a', DROP_ME = 'b' } })
    run({ 'cd /tmp', 'REPO=neovim/neovim', 'export KEEP_ME=changed', 'unset DROP_ME', 'pwd() { echo fake; }', 'declare() { :; }', 'typeset() { :; }' })
    local v = env_view()
    assert(v:match('cwd  /tmp'), sh .. ': cwd shown\n' .. v)
    assert(v:match('\n%+ [^\n]*REPO=[^\n]*neovim/neovim'), sh .. ': new variable marked +\n' .. v)
    assert(v:match('\n~ [^\n]*KEEP_ME=[^\n]*changed'), sh .. ': changed variable marked ~\n' .. v)
    assert(v:match('\n%- DROP_ME'), sh .. ': unset variable marked -\n' .. v)
    assert(not v:match('RANDOM') and not v:match('SECONDS'), sh .. ': noise filtered\n' .. v)
    local log = table.concat(api.nvim_buf_get_lines(vim.fn.bufnr('shrepl-log'), 0, -1, false), '\n')
    assert(not log:match('declare %-p') and not log:match('typeset %-p'), sh .. ': env dumps stay out of the log')
  end
end

print('ok')
vim.cmd('qa!')
