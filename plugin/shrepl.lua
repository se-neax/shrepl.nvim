if vim.g.loaded_shrepl then return end
vim.g.loaded_shrepl = true

local function cmd(name, fn, opts) vim.api.nvim_create_user_command(name, fn, opts or {}) end
cmd('ShreplEval', function(o) require('shrepl').eval(0, o.line1 - 1, o.line2 - 1) end, { range = true })
cmd('ShreplLog', function() require('shrepl').toggle_log() end)
cmd('ShreplLast', function() require('shrepl').open_last() end)
cmd('ShreplInterrupt', function() require('shrepl').interrupt() end)
cmd('ShreplRestart', function() require('shrepl').restart() end)
cmd('ShreplClear', function(o) require('shrepl').clear(o.bang) end, { bang = true })
