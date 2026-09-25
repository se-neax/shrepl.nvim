# shrepl.nvim

Evaluate shell commands from any Neovim buffer, the way Conjure evaluates Clojure.

![shrepl.nvim demo](demo/demo.gif)

Put the cursor on a command, press `<localleader>ee`, and the result shows up at the end
of the line. One shell stays alive behind it, so `REPO=neovim/neovim` on one line is still
set three lines later, and so is a `cd`, a function or an `export`.

I wrote it for runbooks: Markdown files full of `aws`, `kubectl` and `curl | jq` commands
that I used to paste into a terminal one at a time, losing track of which ones I had
already run and what they printed.

## What it does

- Short results appear inline (`=> output`, or `✗ <exit code>` in red). Longer output opens
  in a float under the command; `<localleader>eo` opens all of it in a scratch split, where
  JSON gets folds and `:%!jq` works.
- A sign marks every line you ran, `✓` or `✗`. It stays after you clear the results, so you
  can see how far through a runbook you are.
- In Markdown, `<localleader>er` runs a whole ` ```sh ` block, blank lines included.
  A `python` block is left alone.
- A command continues onto the next line after `\`, `|`, `&&` or `||`, so a split pipeline
  runs as one.
- Commands that look like they change things (`rm`, `aws … delete-*`, `kubectl delete`,
  `terraform apply`, `git push --force`, `DROP TABLE`, …) ask before running. It's a
  check on the text you evaluate, meant to catch the wrong line in a runbook; a script
  you call can still do whatever it likes.
- Slow commands show progress: `… 14s · <latest output line>`. Commands you fire meanwhile
  wait as `… queued`.
- `<localleader>ev` shows the working directory and the variables you've set, changed or
  unset since the shell started.
- A log (`<localleader>ls`) keeps every eval with its full output, exit code and duration.
- A syntax error or an unclosed quote fails only that eval. `<localleader>ei` interrupts a
  hanging command without losing your variables.
- Pagers are off (`PAGER`, `GIT_PAGER`, `AWS_PAGER`), so nothing sits waiting for `q`.

## Install

Needs Neovim 0.10+, bash or zsh, `base64` and `pkill`.

```lua
{ 'se-neax/shrepl.nvim', opts = {} }                                            -- lazy.nvim
use { 'se-neax/shrepl.nvim', config = function() require('shrepl').setup() end } -- packer
```

## Keys

| Key               | Action                                                   |
|-------------------|----------------------------------------------------------|
| `<localleader>ee` | Eval the command under the cursor                        |
| `<localleader>er` | Eval the block around the cursor, or the fenced block    |
| `<localleader>eb` | Eval the whole buffer                                    |
| `<localleader>E`  | Eval the visual selection                                |
| `<localleader>eo` | Open the last result in a scratch split                  |
| `<localleader>ev` | Show the working directory and variables set this session |
| `<localleader>ls` | Toggle the log (`lv` for a vertical split)               |
| `<localleader>ei` | Interrupt the running command                            |
| `<localleader>eR` | Restart the shell                                        |
| `<localleader>ec` | Clear inline results                                     |

They match Conjure's keys, and in buffers where Conjure is active its mappings win. Each
one can be remapped or turned off under `mappings` (for example `eval_buffer = false`).
Everything is also a command, no setup needed: `:ShreplEval` (takes a range),
`:ShreplLog`, `:ShreplLast`, `:ShreplEnv`, `:ShreplInterrupt`, `:ShreplRestart`,
`:ShreplClear` (`!` also removes the signs).

## Configuration

Defaults:

```lua
require('shrepl').setup({
  shell = 'bash', -- 'zsh', 'auto' ($SHELL if it's bash or zsh), or an argv list
  rc = false,     -- true: source ~/.bashrc or ~/.zshrc at start, for your aliases
  env = { PAGER = 'cat', GIT_PAGER = 'cat', AWS_PAGER = '', TERM = 'dumb', NO_COLOR = '1' },
  float = { max_height = 20, max_width = 140, border = 'rounded' },
  signs = { running = '·', ok = '✓', fail = '✗' }, -- or false
  log = { split = 'botright 15split', vsplit = 'botright vsplit' },
  confirm = { add = {} }, -- extra Lua patterns; { patterns = {...} } replaces the defaults; false = off
})
```

For your aliases, `shell = 'zsh', rc = true` works well. Many `~/.bashrc` files return
early in a non-interactive shell, so `rc` does less for bash.

## How it works

The shell runs as a Neovim job on plain pipes. Each eval is sent as

```sh
eval "$(printf %s <base64 of your code> | base64 -d)" </dev/null 2>&1
printf '\n__SHREPL_DONE__ %d\n' $?
```

The base64 means your code can contain any quoting, and a syntax error stays inside `eval`
instead of leaving the shell waiting for a closing quote. `</dev/null` stops a command from
reading the next eval as input. The marker line says where the output ends and what the
exit code was.

## Limits

- No stdin, so prompts, `less` and `top` won't work. Use `:terminal` for those.
- Output arrives line by line; a progress bar that redraws with `\r` shows up once it
  prints a newline.
- bash and zsh only.

## Related

- [Conjure](https://github.com/Olical/conjure), the model for this.
- [vim-slime](https://github.com/jpalardy/vim-slime) sends text to a terminal or tmux pane.
  Better for interactive programs, but results don't come back into the buffer.
- [Lingnik/shrepl.nvim](https://github.com/Lingnik/shrepl.nvim) is an earlier, unrelated
  plugin with the same name. Both use `require('shrepl')`, so install one or the other.

## Tests

```sh
for t in tests/*.lua; do nvim --headless -u NONE --cmd 'set rtp^=.' -l "$t" || break; done
```

## License

MIT
