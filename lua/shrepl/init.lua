-- shrepl.nvim: Conjure-style evaluation for shell. One persistent bash, eval the
-- command/block/selection under the cursor, `=> result` inline, a float for longer
-- output, and a log buffer holding every eval.
local api = vim.api
local M = {}
local ns = api.nvim_create_namespace('shrepl')

M.config = {
  shell = { 'bash', '--norc', '--noprofile' },
  env = { PAGER = 'cat', GIT_PAGER = 'cat', AWS_PAGER = '', TERM = 'dumb', NO_COLOR = '1' },
  float = { max_height = 20, max_width = 140, border = 'rounded' },
  log = { split = 'botright 15split', vsplit = 'botright vsplit' },
  mappings = {
    eval_command = '<localleader>ee',
    eval_block = '<localleader>er',
    eval_buffer = '<localleader>eb',
    eval_selection = '<localleader>E',
    interrupt = '<localleader>ei',
    restart = '<localleader>eR',
    clear = '<localleader>ec',
    open_last = '<localleader>eo',
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
    api.nvim_buf_set_lines(log_buf, 0, -1, false, { '# shrepl log (one persistent bash)' })
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
  e.logged = true
  append({ '# ── ' .. os.date('%H:%M:%S') }); append(e.code)
end

local function push(e, l)
  header(e)
  for _ = 1, e.blanks do table.insert(e.out, ''); append({ '' }) end
  e.blanks = 0
  table.insert(e.out, l); append({ l })
end

local function finish(rc)
  local e = table.remove(queue, 1)
  if not e then return end
  header(e)
  e.blanks = 0 -- trailing blank lines (incl. the sentinel printf's \n) are dropped
  append({ ('# => exit %d  (%.1fs)'):format(rc, (vim.uv.hrtime() - e.t0) / 1e9), '' })
  last = e.out
  local more = #e.out > 1 and ('  …+%d'):format(#e.out - 1) or ''
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

local function ensure()
  if job then return end
  partial = ''
  job = vim.fn.jobstart(M.config.shell, {
    env = M.config.env,
    on_stdout = on_out,
    on_stderr = function(_, d) append(vim.tbl_filter(function(l) return l ~= '' end, d)) end,
    on_exit = vim.schedule_wrap(function()
      for _, e in ipairs(queue) do mark(e, '✗ shell exited', 'DiagnosticError') end
      queue, job = {}, nil
      append({ '# shell exited, next eval starts a fresh one', '' })
    end),
  })
end

--- Evaluate rows s..e (0-based, inclusive) of `buf`, removing up to `dedent` leading
--- spaces per line (fenced blocks inside Markdown lists). Code travels base64 through
--- eval, so a syntax error or unclosed quote can't swallow the end marker, and
--- </dev/null stops commands from reading the plugin's own input.
function M.eval(buf, s, e, dedent)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local lines = api.nvim_buf_get_lines(buf, s, e + 1, false)
  if (dedent or 0) > 0 then
    for i, l in ipairs(lines) do lines[i] = l:sub(math.min(#l:match('^ *'), dedent) + 1) end
  end
  ensure()
  local ev = { buf = buf, last = e, code = lines, out = {}, blanks = 0, t0 = vim.uv.hrtime() }
  api.nvim_buf_clear_namespace(buf, ns, s, e + 1)
  mark(ev, '… running', 'Comment')
  table.insert(queue, ev)
  if #queue == 1 then header(ev) end
  local wrap = [[eval "$(printf %s CODE | base64 -d)" </dev/null 2>&1; printf '\n__SHREPL_DONE__ %d\n' $?]]
  vim.fn.chansend(job, wrap:gsub('CODE', vim.base64.encode(table.concat(lines, '\n')), 1) .. '\n')
end

local function line(i) return api.nvim_buf_get_lines(0, i, i + 1, false)[1] end
local function around(ext) -- grow from the cursor row while ext(row) holds
  local r, n = api.nvim_win_get_cursor(0)[1] - 1, api.nvim_buf_line_count(0)
  local s, e = r, r
  while s > 0 and ext(s - 1, 'up') do s = s - 1 end
  while e < n - 1 and ext(e, 'down') do e = e + 1 end
  return s, e
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
  command = function() return around(function(i) return line(i):match('\\%s*$') end) end,
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
function M.clear() api.nvim_buf_clear_namespace(0, ns, 0, -1) end

--- Toggle the log window; `cmd` is the split command (default: config.log.split).
function M.toggle_log(cmd)
  local w = vim.fn.win_findbuf(log())[1]
  if w then return api.nvim_win_close(w, false) end
  local cur = api.nvim_get_current_win()
  vim.cmd((cmd or M.config.log.split) .. ' | buffer ' .. log())
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(log_buf), 0 })
  api.nvim_set_current_win(cur)
end

--- The last result in a scratch split: search, fold, :%!jq, yank.
function M.open_last()
  vim.cmd('botright new')
  api.nvim_buf_set_lines(0, 0, -1, false, last)
  vim.bo.buftype, vim.bo.bufhidden = 'nofile', 'wipe'
  vim.bo.filetype = (last[1] or ''):match('^%s*[%[{]') and 'json' or 'text'
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
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
  map('n', m.log_split, function() M.toggle_log(M.config.log.split) end, 'toggle log (split)')
  map('n', m.log_vsplit, function() M.toggle_log(M.config.log.vsplit) end, 'toggle log (vsplit)')
end

return M
