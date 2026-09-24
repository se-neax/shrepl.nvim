# shrepl.nvim

Evaluate shell commands from any Neovim buffer, the way Conjure evaluates Clojure.

![shrepl.nvim demo](demo/demo.gif)

Put the cursor on a line, press `<localleader>ee`, and the result shows up at the end of
that line. A line ending in `\`, `|`, `&&` or `||` pulls in the next one, so a pipeline
split over three lines runs as one command. The shell behind it stays alive between evals. If one line sets `B=my-bucket`,
`aws s3 ls s3://$B` three lines further down still sees it, and a `cd`, a function or an
`export` sticks around the same way.

I wrote it for runbooks. I kept a Markdown file of `aws`, `kubectl` and `curl | jq`
commands and pasted them into a terminal one at a time, and I kept losing track of which
ones I had already run and what they had printed. Now the answer sits next to each
command.

## What it does

Every line you run gets a sign in the sign column: `·` while it runs, then `✓` or a red
`✗`. The signs stay when you clear the inline results and move with the text as you edit,
so halfway through a runbook you can see which steps you already did. `:ShreplClear!`
wipes them.

While a command runs, its line shows how long it has been going and the latest line of
output (`… 14s · Waiting for stack update`), so a slow `aws` call doesn't look frozen.
Commands you fired while another was still running wait their turn and say `… queued`.

A short result goes inline: `=> first line of output` in a muted color, with `…+N` when
there's more, or `✗ <exit code>` in red when the command fails. Longer output also opens
in a float under the command you ran, so it doesn't cover the code, and it closes when you
move the cursor.

For really long output (an `aws ... list-*` call can easily return 16,000 lines),
`<localleader>eo` opens the last result in a scratch split. JSON gets `filetype=json`, so
you can fold it, search it, or cut it down with `:%!jq '.Items[].id'`.

Everything also goes to a log (`<localleader>ls`): each eval's code, its full output, the
exit code and how long it took, in the order you ran them. The log never truncates.

A broken command only breaks itself. An unclosed quote or a syntax error fails that one
eval and the shell carries on. If something hangs, `<localleader>ei` interrupts it and
your variables survive.

Commands that look like they change things ask first: `rm`, `aws … delete-*/put-*/create-*`
and friends, `aws s3 rm/sync/mv` or a `cp` to `s3://`, `kubectl delete/apply`,
`terraform apply/destroy`, `git push --force`, `git reset --hard`, `DROP TABLE`,
`DELETE FROM`, `dd … of=`. It's pattern matching on the text you evaluate, so it catches
the typo'd line in a runbook, not a script that deletes things on its own. Add your own
with `confirm = { add = { '%f[%w]deploy%.sh' } }`, or turn it off with `confirm = false`.

Pagers are switched off (`PAGER`, `GIT_PAGER` and `AWS_PAGER`), because a command waiting
for you to press `q` in an invisible pager just looks like a hang.

It works in any buffer, whatever the filetype. In Markdown, `<localleader>er` inside a
fenced block (```` ``` ```` or `~~~`, also when indented under a list item) runs the whole
block, blank lines included. That happens when the fence is marked `sh`, `bash`, `shell`,
`zsh`, `console` (or `{bash}`) or has no language; a `python` block is left alone.

## Install

Requires Neovim 0.10+, `bash` (or `zsh`), `base64` and `pkill` (coreutils and procps, present on
most systems).

lazy.nvim:

```lua
{ 'se-neax/shrepl.nvim', opts = {} }
```

packer.nvim:

```lua
use { 'se-neax/shrepl.nvim', config = function() require('shrepl').setup() end }
```

## Keys

| Key               | Action                                                  |
|-------------------|---------------------------------------------------------|
| `<localleader>ee` | Eval the current command, across `\` `|` `&&` `||` line ends |
| `<localleader>er` | Eval the block around the cursor, or the fenced block   |
| `<localleader>eb` | Eval the whole buffer                                   |
| `<localleader>E`  | Eval the visual selection                               |
| `<localleader>eo` | Open the last result in a scratch split                 |
| `<localleader>ls` | Toggle the log in a horizontal split                    |
| `<localleader>lv` | Toggle the log in a vertical split                      |
| `<localleader>ei` | Interrupt the running command                           |
| `<localleader>eR` | Restart the shell                                       |
| `<localleader>ec` | Clear inline results                                    |

If you already use Conjure, these match its keys. In buffers where Conjure is active, its
buffer-local mappings win.

Every mapping can be changed or turned off:

```lua
require('shrepl').setup({
  mappings = {
    eval_command = '<leader>r', -- any lhs
    eval_buffer = false,        -- disabled
  },
})
```

The same actions exist as commands, with no setup needed: `:ShreplEval` (takes a range),
`:ShreplLog`, `:ShreplLast`, `:ShreplInterrupt`, `:ShreplRestart`, `:ShreplClear` (`!` also clears the signs).

## Configuration

Defaults:

```lua
require('shrepl').setup({
  shell = 'bash', -- 'zsh', 'auto' ($SHELL if bash/zsh), or an argv list
  rc = false,     -- true: source ~/.bashrc / ~/.zshrc at start (aliases, functions)
  env = { PAGER = 'cat', GIT_PAGER = 'cat', AWS_PAGER = '', TERM = 'dumb', NO_COLOR = '1' },
  float = { max_height = 20, max_width = 140, border = 'rounded' },
  signs = { running = '·', ok = '✓', fail = '✗' }, -- or false
  log = { split = 'botright 15split', vsplit = 'botright vsplit' },
  confirm = { add = {} }, -- or { patterns = { ... } } to replace the defaults, or false
})
```

`shell = 'zsh', rc = true` gets you your aliases and functions from `~/.zshrc`. The rc
file is sourced once when the shell starts and shows up in the log like any other eval.
bash works the same way, but many `~/.bashrc` files return early when the shell isn't
interactive, so the aliases may never get defined.

## How it works

One shell (bash by default) runs as a Neovim job with plain pipes, no terminal. Each eval is sent as

```sh
eval "$(printf %s <base64 of your code> | base64 -d)" </dev/null 2>&1
printf '\n__SHREPL_DONE__ %d\n' $?
```

Because the code travels as base64, it can contain any quoting at all, and a syntax error
stays inside `eval` instead of leaving bash waiting for a closing quote. `</dev/null` stops a command
from reading the next eval as its input. The marker line tells shrepl where the output
ends and what the exit code was. Evals queue in order, so you can fire several without
waiting.

## Limits

- No stdin: prompts, `less`, `top` and other interactive programs won't work. Use
  `:terminal` for those.
- Output arrives line by line, so a progress bar that redraws with `\r` shows up only
  once it prints a newline.
- bash and zsh only. fish uses different syntax for the wrapper and isn't supported.

## Related

- [Conjure](https://github.com/Olical/conjure): the model for this, for Lisps and more.
- [vim-slime](https://github.com/jpalardy/vim-slime): sends text to a terminal or tmux
  pane. Better for interactive programs, but results don't come back into the buffer.
- [Lingnik/shrepl.nvim](https://github.com/Lingnik/shrepl.nvim): an earlier, unrelated
  plugin with the same name and a similar goal. Both use `require('shrepl')`, so install
  one or the other.

## Tests

```sh
nvim --headless -u NONE --cmd 'set rtp^=.' -l tests/smoke.lua
```

## License

MIT
