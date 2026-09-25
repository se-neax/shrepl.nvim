-- shrepl.nvim: Conjure-style evaluation for shell. One persistent bash, eval the
-- command/block/selection under the cursor, `=> result` inline, a float for longer
-- output, and a log buffer holding every eval.
local api = vim.api
local M = {}
local ns = api.nvim_create_namespace('shrepl')
local sign_ns = api.nvim_create_namespace('shrepl_signs') -- survives clear(), so you can see what already ran

M.config = {
  shell = 'bash', -- 'bash', 'zsh', 'auto' ($SHELL when it is bash or zsh), or an argv list
  rc = false,     -- source ~/.bashrc or ${ZDOTDIR:-~}/.zshrc at start, for aliases and functions
  env = { PAGER = 'cat', GIT_PAGER = 'cat', AWS_PAGER = '', TERM = 'dumb', NO_COLOR = '1' },
  float = { max_height = 20, max_width = 140, border = 'rounded' },
  signs = { running = '·', ok = '✓', fail = '✗' }, -- sign column per evaluated line; false = off
  log = { split = 'botright 15split', vsplit = 'botright vsplit' },
  -- A guardrail, not a sandbox: each entry is a Lua pattern or a function(line) -> bool,
  -- tried on every logical line (\ continuations joined, lowercased). A hit asks first.
  -- `patterns` replaces the list, `add` extends it, `confirm = false` turns it off.
  confirm = { add = {}, patterns = {} },
  mappings = {
    eval_command = '<localleader>ee',
    eval_block = '<localleader>er',
    eval_buffer = '<localleader>eb',
    eval_selection = '<localleader>E',
    interrupt = '<localleader>ei',
    restart = '<localleader>eR',
    clear = '<localleader>ec',
    open_last = '<localleader>eo',
    show_env = '<localleader>ev',
    log_split = '<localleader>ls',
    log_vsplit = '<localleader>lv',
  },
}

local job, partial, queue, log_buf, last = nil, '', {}, nil, {}

local function log()
  if not (log_buf and api.nvim_buf_is_valid(log_buf)) then
    log_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(log_buf, 'shrepl-log')
    vim.bo[log_buf].filetype = 'sh'
    api.nvim_buf_set_lines(log_buf, 0, -1, false, { '# shrepl log (one persistent shell)' })
  end
  return log_buf
end

local function append(lines)
  local b = log()
  api.nvim_buf_set_lines(b, -1, -1, false, lines)
  for _, w in ipairs(vim.fn.win_findbuf(b)) do
    if w ~= api.nvim_get_current_win() then api.nvim_win_set_cursor(w, { api.nvim_buf_line_count(b), 0 }) end
  end
end

local function mark(e, text, hl)
  if e.stale then return end
  pcall(function()
    local row = e.mark and api.nvim_buf_get_extmark_by_id(e.buf, ns, e.mark, {})[1] or e.last
    e.mark = api.nvim_buf_set_extmark(e.buf, ns, row, 0, { id = e.mark, virt_text = { { text, hl } } })
  end)
end

local function open_last_hint()
  local lhs = M.config.mappings.open_last
  if not lhs then return ':ShreplLast' end
  local ll = vim.g.maplocalleader or '\\'
  return (lhs:gsub('<[Ll]ocal[Ll]eader>', ll):gsub('<[Ll]eader>', vim.g.mapleader or '\\'))
end

-- float anchored under the last evaluated line, so it never hides the code or its result
local sign_hl = { running = 'Comment', ok = 'DiagnosticOk', fail = 'DiagnosticError' }
local function sign(e, state)
  local cfg = M.config.signs
  if not cfg or e.stale or not e.buf then return end
  e.signs = e.signs or {}
  for i = e.first, e.last do
    pcall(function()
      local id = e.signs[i]
      local row = id and api.nvim_buf_get_extmark_by_id(e.buf, sign_ns, id, {})[1] or i
      e.signs[i] = api.nvim_buf_set_extmark(e.buf, sign_ns, row, 0, { id = id, sign_text = cfg[state], sign_hl_group = sign_hl[state] })
    end)
  end
end

local function float(lines, row)
  local cfg = M.config.float
  local title = (' %d lines · all: %s '):format(#lines, open_last_hint())
  local width = vim.fn.strdisplaywidth(title) + 2
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = api.nvim_open_win(buf, false, {
    relative = 'win', bufpos = { row, 0 }, row = 1, col = 0, style = 'minimal', border = cfg.border,
    width = math.min(width, cfg.max_width), height = math.min(#lines, cfg.max_height),
    title = title, title_pos = 'right',
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufLeave' }, {
    once = true, callback = function() pcall(api.nvim_win_close, win, true) end,
  })
end

-- header+code logged when the eval reaches the head of the queue, so queued evals
-- don't interleave their transcripts
local function header(e)
  if e.logged then return end
  e.logged, e.t0 = true, vim.uv.hrtime() -- the eval starts running now
  if e.buf then mark(e, '… running', 'Comment') end
  if not e.quiet then append({ '# ── ' .. os.date('%H:%M:%S') }); append(e.code) end
end

local function push(e, l)
  header(e)
  for _ = 1, e.blanks do table.insert(e.out, ''); if not e.quiet then append({ '' }) end end
  e.blanks = 0
  table.insert(e.out, l)
  if not e.quiet then append({ l }) end
end

local function finish(rc)
  local e = table.remove(queue, 1)
  if not e then return end
  header(e)
  e.blanks = 0 -- trailing blank lines (incl. the sentinel printf's \n) are dropped
  if not e.quiet then append({ ('# => exit %d  (%.1fs)'):format(rc, (vim.uv.hrtime() - e.t0) / 1e9), '' }) end
  if e.on_done then e.on_done(e.out, rc) end
  if e.internal then return end
  last = e.out
  local more = #e.out > 1 and ('  …+%d'):format(#e.out - 1) or ''
  sign(e, rc == 0 and 'ok' or 'fail')
  if rc == 0 then mark(e, '=> ' .. (e.out[1] or '') .. more, 'Comment')
  else mark(e, ('✗ %d  %s%s'):format(rc, e.out[1] or '', more), 'DiagnosticError') end
  if #e.out > 1 and api.nvim_get_current_buf() == e.buf and #vim.fn.win_findbuf(log()) == 0 then
    local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, e.buf, ns, e.mark, {})
    float(e.out, ok and pos[1] or e.last)
  end
end

local function on_out(_, data)
  data[1] = partial .. data[1]
  partial = table.remove(data)
  for _, l in ipairs(data) do
    l = l:gsub('\27%[[%d;?]*%a', ''):gsub('\r', '')
    local rc = l:match('^__SHREPL_DONE__ (%d+)$')
    local e = queue[1]
    if rc then
      finish(tonumber(rc))
      if queue[1] then header(queue[1]) end
    elseif e and l == '' then e.blanks = e.blanks + 1
    elseif e then push(e, l) end
  end
end

local shells = {
  bash = { argv = { 'bash', '--norc', '--noprofile' }, rc = 'shopt -s expand_aliases; [ -f ~/.bashrc ] && . ~/.bashrc' },
  zsh = { argv = { 'zsh', '-f' }, rc = '[ -f "${ZDOTDIR:-$HOME}/.zshrc" ] && . "${ZDOTDIR:-$HOME}/.zshrc"' },
}

-- argv and rc snippet for config.shell
local function shell_cmd()
  local sh = M.config.shell
  if sh == 'auto' then
    sh = vim.fs.basename(vim.env.SHELL or '')
    if not shells[sh] then sh = 'bash' end
  end
  if type(sh) == 'string' then
    assert(shells[sh], 'shrepl: unknown shell ' .. sh .. " (use 'bash', 'zsh', 'auto' or an argv list)")
    return shells[sh].argv, shells[sh].rc
  end
  local known = shells[vim.fs.basename(sh[1])]
  return sh, known and known.rc
end

-- once a second: the running eval's mark shows elapsed time and its latest output line
local ticker
local function tick()
  local e = queue[1]
  if not e then ticker:stop(); return end
  if e.internal or not e.buf then return end
  local secs = math.floor((vim.uv.hrtime() - e.t0) / 1e9)
  local tail = e.out[#e.out] and (' · ' .. vim.fn.strcharpart(vim.trim(e.out[#e.out]), 0, 60)) or ''
  mark(e, ('… %ds%s'):format(secs, tail), 'Comment')
end
local function start_ticker()
  ticker = ticker or vim.uv.new_timer()
  if not ticker:is_active() then ticker:start(1000, 1000, vim.schedule_wrap(tick)) end
end

local dispatch, shell_name, baseline

-- run code the user didn't write (rc file, env snapshots); never marks a buffer
local function internal(code, opts)
  local ev = vim.tbl_extend('force', { code = { code }, out = {}, blanks = 0, t0 = vim.uv.hrtime(), internal = true }, opts or {})
  table.insert(queue, ev)
  if #queue == 1 then header(ev) end
  dispatch(ev)
end

-- variables that change on their own or belong to the shell, never interesting in a diff
local noise = {}
for n in ([[_ RANDOM SRANDOM SECONDS LINENO EPOCHSECONDS EPOCHREALTIME BASH_COMMAND BASH_LINENO
  BASH_SOURCE BASH_ARGC BASH_ARGV BASH_REMATCH FUNCNAME PIPESTATUS BASHPID HISTCMD COLUMNS LINES PWD
  OLDPWD pipestatus status ERRNO TTYIDLE funcstack funcfiletrace funcsourcetrace functrace
  zsh_eval_context ZSH_EVAL_CONTEXT ZSH_SUBSHELL]]):gmatch('%S+') do noise[n] = true end

-- `declare -p` / `typeset -p` output -> { name = definition }
local function parse_vars(lines)
  local vars, name = {}, nil
  for _, l in ipairs(lines) do
    local words, n = vim.split(l, ' ', { trimempty = true }), nil
    if vim.tbl_contains({ 'declare', 'typeset', 'export', 'readonly', 'local' }, words[1]) then
      for i = 2, #words do
        if not words[i]:match('^[-+]') then n = words[i]:match('^([%w_]+)'); break end
      end
    end
    if n then name = n; vars[name] = l
    elseif name then vars[name] = vars[name] .. '\n' .. l end
  end
  for k in pairs(vars) do if noise[k] or k:match('^__shrepl') then vars[k] = nil end end
  return vars
end

-- builtin: a user function or alias named declare/typeset/pwd must not answer instead
local function dump_cmd() return shell_name == 'zsh' and 'builtin typeset -p' or 'builtin declare -p' end

local function ensure()
  if job then return end
  partial = ''
  local argv, rc = shell_cmd()
  shell_name, baseline = vim.fs.basename(argv[1]), nil
  job = vim.fn.jobstart(argv, {
    env = M.config.env,
    on_stdout = on_out,
    on_stderr = function(_, d) append(vim.tbl_filter(function(l) return l ~= '' end, d)) end,
    on_exit = vim.schedule_wrap(function()
      for _, e in ipairs(queue) do mark(e, '✗ shell exited', 'DiagnosticError'); sign(e, 'fail') end
      queue, job = {}, nil
      append({ '# shell exited, next eval starts a fresh one', '' })
    end),
  })
  if M.config.rc and rc then internal(rc) end
  internal(dump_cmd(), { quiet = true, on_done = function(out) baseline = parse_vars(out) end })
end

-- the base64 wrapper works unchanged in bash and zsh
function dispatch(ev)
  local wrap = [[eval "$(printf %s CODE | base64 -d)" </dev/null 2>&1; printf '\n__SHREPL_DONE__ %d\n' $?]]
  vim.fn.chansend(job, wrap:gsub('CODE', vim.base64.encode(table.concat(ev.code, '\n')), 1) .. '\n')
end

--- Evaluate rows s..e (0-based, inclusive) of `buf`, removing up to `dedent` leading
--- spaces per line (fenced blocks inside Markdown lists). Code travels base64 through
--- eval, so a syntax error or unclosed quote can't swallow the end marker, and
--- </dev/null stops commands from reading the plugin's own input.
-- tool + verb anywhere later on the line, so global flags (-n prod, -chdir=x, --profile p)
-- can't hide the verb
local function verbs(tool, list)
  return vim.tbl_map(function(v) return '%f[%w]' .. tool .. '%f[%W].-%f[%w]' .. v end, list)
end

-- aws s3 cp: a write when any positional after the source is an s3:// URL
local function s3_cp_upload(l)
  local args = l:match('%f[%w]aws%f[%W].-%f[%w]s3%s+cp%s+(.*)')
  if not args then return false end
  local pos = {}
  for tok in args:gmatch('%S+') do
    tok = tok:gsub('[\'"]', '')
    if not tok:match('^%-') then table.insert(pos, tok) end
  end
  for i = 2, #pos do if pos[i]:match('^s3://') then return true end end
  return false
end

M.default_confirm = vim.iter({
  { '%f[%w]rm%s', '%f[%w]rmdir%s', '%f[%w]dd%f[%W].-%f[%w]of=', '%f[%w]mkfs', '%f[%w]shutdown%f[%W]', '%f[%w]reboot%f[%W]',
    '%f[%w]drop%s+table', '%f[%w]drop%s+database', '%f[%w]truncate%s', '%f[%w]delete%s+from%f[%W]', s3_cp_upload },
  verbs('aws', { 's3%s+rm%f[%W]', 's3%s+rb%f[%W]', 's3%s+mv%f[%W]', 's3%s+sync%f[%W]', 'delete', 'put%-', 'create',
    'update', 'modify', 'terminate', 'remove', 'stop%-', 'reboot', 'invoke', 'run%-' }),
  verbs('kubectl', { 'delete', 'apply', 'replace', 'patch', 'scale', 'drain', 'rollout%s+restart' }),
  verbs('helm', { 'uninstall', 'upgrade', 'rollback' }),
  verbs('terraform', { 'apply', 'destroy', 'state%s+rm', 'import' }),
  verbs('git', { 'push%f[%W].-%-%-force', 'push%f[%W].-%s%-%a*f', 'reset%f[%W].-%-%-hard',
    'clean%f[%W].-%s%-%a*f', 'clean%f[%W].-%-%-force' }),
  verbs('docker', { 'system%s+prune', 'volume%s+rm', 'rm%f[%W]', 'rmi%f[%W]' }),
  verbs('systemctl', { 'stop', 'disable', 'restart' }),
}):flatten():totable()
M.config.confirm.patterns = M.default_confirm

local function logical_lines(lines)
  local out, cur = {}, ''
  for _, l in ipairs(lines) do
    if l:match('\\%s*$') then cur = cur .. (l:gsub('\\%s*$', ' '))
    else table.insert(out, cur .. l); cur = '' end
  end
  if cur ~= '' then table.insert(out, cur) end
  return out
end

--- First logical line of `lines` matching a confirm pattern, or nil.
function M.needs_confirm(lines)
  local c = M.config.confirm
  if not c then return end
  local checks = vim.list_extend(vim.list_extend({}, c.patterns or {}), c.add or {})
  for _, l in ipairs(logical_lines(lines)) do
    local low = l:lower()
    for _, p in ipairs(checks) do
      if (type(p) == 'function' and p(low)) or (type(p) == 'string' and low:match(p)) then return vim.trim(l) end
    end
  end
end

function M.eval(buf, s, e, dedent)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local lines = api.nvim_buf_get_lines(buf, s, e + 1, false)
  if (dedent or 0) > 0 then
    for i, l in ipairs(lines) do lines[i] = l:sub(math.min(#l:match('^ *'), dedent) + 1) end
  end
  local hit = M.needs_confirm(lines)
  if hit and vim.fn.confirm('shrepl: this looks like it changes things:\n\n  ' .. hit .. '\n\nRun it?', '&Run\n&Cancel', 2, 'Warning') ~= 1 then
    api.nvim_buf_clear_namespace(buf, ns, s, e + 1)
    mark({ buf = buf, last = e }, '⊘ not run', 'DiagnosticWarn')
    return
  end
  ensure()
  local ev = { buf = buf, first = s, last = e, code = lines, out = {}, blanks = 0, t0 = vim.uv.hrtime() }
  -- a queued eval on the same lines no longer owns their marks
  for _, q in ipairs(queue) do
    if q.buf == buf and q.first <= e and s <= q.last then q.stale = true end
  end
  api.nvim_buf_clear_namespace(buf, ns, s, e + 1)
  api.nvim_buf_clear_namespace(buf, sign_ns, s, e + 1)
  local waiting = vim.iter(queue):any(function(q) return not q.internal end)
  table.insert(queue, ev)
  mark(ev, waiting and '… queued' or '… running', 'Comment')
  sign(ev, 'running')
  start_ticker()
  if #queue == 1 then header(ev) end
  dispatch(ev)
end

local function line(i) return api.nvim_buf_get_lines(0, i, i + 1, false)[1] end
local function around(ext) -- grow from the cursor row while ext(row) holds
  local r, n = api.nvim_win_get_cursor(0)[1] - 1, api.nvim_buf_line_count(0)
  local s, e = r, r
  while s > 0 and ext(s - 1, 'up') do s = s - 1 end
  while e < n - 1 and ext(e, 'down') do e = e + 1 end
  return s, e
end

-- a line ending in \, |, || or && carries on to the next one; an escaped \| or an
-- operator inside a trailing comment does not
local function continues(l)
  if l:match('^%s*#') then return false end
  l = l:gsub('%s#[^\'"]*$', '')
  return (l:match('\\%s*$') or l:match('[^\\]|%s*$') or l:match('&&%s*$')) ~= nil
end

local shell_langs = { [''] = true, sh = true, bash = true, shell = true, zsh = true, console = true }

-- Markdown fence (``` or ~~~) containing the cursor row, delimiter lines included:
-- returns the opening and closing rows (0-based; close = line count when unclosed).
local function fence()
  local r, lines = api.nvim_win_get_cursor(0)[1] - 1, api.nvim_buf_get_lines(0, 0, -1, false)
  local open, delim
  for i, l in ipairs(lines) do
    local row, f = i - 1, l:match('^%s*(```+)') or l:match('^%s*(~~~+)')
    if f and not open then
      open, delim = row, f
    elseif f and f:sub(1, 1) == delim:sub(1, 1) and #f >= #delim and l:match('^%s*[`~]+%s*$') then
      if r <= row then return open, row end
      open = nil
    end
    if row >= r and not open then return nil end
  end
  if open then return open, #lines end
end

M.ranges = {
  command = function() return around(function(i) return continues(line(i)) end) end,
  block = function()
    local open, close = fence()
    if not open then -- blank-line delimited; fence lines count as delimiters too
      return around(function(i, dir)
        local l = line(dir == 'up' and i or i + 1)
        return l:match('%S') and not l:match('^%s*```') and not l:match('^%s*~~~')
      end)
    end
    -- info string: `sh`, `{bash}`, `{.bash}`; anything unparsed counts as not shell
    local info = vim.trim(line(open):match('^%s*[`~]+(.*)'))
    local lang = info:gsub('^{%.?', ''):match('^[%w-]*'):lower()
    if lang == '' and info ~= '' then lang = info end
    if not shell_langs[lang] then vim.notify('shrepl: not a shell block (' .. lang .. ')', vim.log.levels.WARN); return end
    if close - open < 2 then vim.notify('shrepl: empty block', vim.log.levels.WARN); return end
    return open + 1, close - 1, #line(open):match('^%s*') -- body is dedented by the fence's indent
  end,
  buffer = function() return 0, api.nvim_buf_line_count(0) - 1 end,
  selection = function()
    local s, e = vim.fn.line('v') - 1, vim.fn.line('.') - 1
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    if s > e then s, e = e, s end
    return s, e
  end,
}

function M.interrupt()
  if job then vim.fn.system({ 'pkill', '-INT', '-P', tostring(vim.fn.jobpid(job)) }) end
end
function M.restart() if job then vim.fn.jobstop(job) end end
--- Clear inline results; with `signs = true` also the ran/failed signs.
function M.clear(signs)
  api.nvim_buf_clear_namespace(0, ns, 0, -1)
  if signs then api.nvim_buf_clear_namespace(0, sign_ns, 0, -1) end
end

--- Toggle the log window; `cmd` is the split command (default: config.log.split).
function M.toggle_log(cmd)
  local w = vim.fn.win_findbuf(log())[1]
  if w then return api.nvim_win_close(w, false) end
  local cur = api.nvim_get_current_win()
  vim.cmd((cmd or M.config.log.split) .. ' | buffer ' .. log())
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(log_buf), 0 })
  api.nvim_set_current_win(cur)
end

--- Working directory plus variables set, changed or unset since the shell started.
function M.show_env()
  if not job then return vim.notify('shrepl: no shell running yet', vim.log.levels.INFO) end
  internal('builtin pwd; ' .. dump_cmd(), { quiet = true, on_done = function(out)
    local now = parse_vars(vim.list_slice(out, 2))
    local lines = { '# shrepl env (' .. shell_name .. ')', 'cwd  ' .. (out[1] or '?'), '' }
    local names = vim.tbl_keys(vim.tbl_extend('force', {}, baseline or {}, now))
    table.sort(names)
    for _, n in ipairs(names) do
      local was, is = (baseline or {})[n], now[n]
      if not was then table.insert(lines, '+ ' .. is)
      elseif not is then table.insert(lines, '- ' .. n .. '  (unset)')
      elseif was ~= is then table.insert(lines, '~ ' .. is) end
    end
    if #lines == 3 then table.insert(lines, '(nothing set or changed since the shell started)') end
    vim.cmd('botright new')
    api.nvim_buf_set_lines(0, 0, -1, false, vim.iter(lines):map(function(l) return vim.split(l, '\n') end):flatten():totable())
    vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = 'nofile', 'wipe', 'sh'
  end })
end

--- The last result in a scratch split: search, fold, :%!jq, yank.
function M.open_last()
  vim.cmd('botright new')
  api.nvim_buf_set_lines(0, 0, -1, false, last)
  vim.bo.buftype, vim.bo.bufhidden = 'nofile', 'wipe'
  vim.bo.filetype = (last[1] or ''):match('^%s*[%[{]') and 'json' or 'text'
end

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend('force', M.config, opts)
  -- lists replace instead of merging index by index
  if opts.shell then M.config.shell = opts.shell end
  if type(opts.confirm) == 'table' then
    for _, k in ipairs({ 'patterns', 'add' }) do
      if opts.confirm[k] then M.config.confirm[k] = opts.confirm[k] end
    end
  end
  local m = M.config.mappings
  local function map(mode, lhs, fn, desc)
    if lhs then vim.keymap.set(mode, lhs, fn, { desc = 'shrepl: ' .. desc }) end
  end
  local run = function(range) return function()
    local s, e, dedent = M.ranges[range]()
    if s then M.eval(0, s, e, dedent) end
  end end
  map('n', m.eval_command, run('command'), 'eval command (follows \\ continuations)')
  map('n', m.eval_block, run('block'), 'eval block (blank-line delimited)')
  map('n', m.eval_buffer, run('buffer'), 'eval buffer')
  map('x', m.eval_selection, run('selection'), 'eval selection')
  map('n', m.interrupt, M.interrupt, 'interrupt')
  map('n', m.restart, M.restart, 'restart shell')
  map('n', m.clear, M.clear, 'clear inline results')
  map('n', m.open_last, M.open_last, 'open last result')
  map('n', m.show_env, M.show_env, 'show cwd and variables set this session')
  map('n', m.log_split, function() M.toggle_log(M.config.log.split) end, 'toggle log (split)')
  map('n', m.log_vsplit, function() M.toggle_log(M.config.log.vsplit) end, 'toggle log (vsplit)')
end

return M
