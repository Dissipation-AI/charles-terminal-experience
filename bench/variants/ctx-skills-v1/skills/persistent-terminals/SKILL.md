---
name: persistent-terminals
description: Keeps a program open in a ctx tab and drives it across tool calls - interactive consoles and CLIs that refuse to run without a terminal, setup wizards, REPLs (python, node), debuggers (pdb, gdb, lldb), ssh, adb and database shells. Use when a program needs a TTY or prompts for input, when starting it or loading its data is slow, or when each new session or load gives different state, so that re-running it for every question would be slow or wrong.
---

# Persistent terminals with ctx

A ctx tab is a real terminal that stays open between your tool calls. Start the program there once, then type into it and read what it printed, as many times as you need.

If one command answers the question, use that instead: `python -c`, `gdb -batch -ex bt`, `psql -c`, `ssh host 'cmd'`, or piping the input in when the program accepts a pipe.

## The loop

Open a tab, start the program without waiting, then send input and read the answer. Chain each round into one call with `&&`:

```
ctx open tab named "Console - ops" at /abs/path/to/project
ctx run in "Console - ops" "./console" without waiting && ctx wait until "Console - ops" shows "ops>" within 3 minutes
ctx type 'alerts' into "Console - ops" then press enter && ctx wait until "Console - ops" is quiet for 2 seconds && ctx read last 15 lines in "Console - ops"
```

- `type` goes to whatever owns the tab; `then press enter` submits the line.
- One `type` can carry several lines; each is entered in turn. If you already know every answer a wizard will ask for, type them all at once: input typed ahead waits for the program's next prompt.

  ```
  ctx run in "Setup" "./configure" without waiting && ctx type 'billing
  9040
  y' into "Setup" then press enter && ctx wait until "Setup" is idle within 1 minutes && ctx read last command in "Setup"
  ```
- Waiting: `shows "<text>"` matches anything the program printed since it started, including your own typed input and earlier prompts, so after the first round wait for text only the new answer can contain, or `is quiet for 2 seconds`. `is idle` means the program exited. Never `sleep`.
- Reading: `ctx read last 20 lines in "<tab>"` after each round; `ctx read "<tab>"` shows the current screen of a full-screen program.
- Keys: `ctx press ctrl-c in "<tab>"`, `ctrl-d`, `escape`, `q`.
- Your shell tool's own ways of sending input to a background command don't reach a program in a ctx tab. Use `ctx type`.

## Rules that keep it working

1. End a batch at any line that hands the terminal to the program (`run` or `continue` in a debugger, `ssh`, a nested REPL). Send it alone, wait for the stop, then send the next lines.
2. Python REPL: start it as `PYTHON_BASIC_REPL=1 python3 -q` so a multi-line `type` is entered line by line; put a blank line after an indented block.
3. Meta-commands (sqlite3 `.mode`, psql `\d`, IPython `%magic`) go in their own `type`.
4. Some exits ask first (`[Y/n]`). If a wait times out, `ctx read "<tab>"` before anything else.
5. Passwords and 2FA codes are the user's: get to the prompt, `ctx show "<tab>"`, ask them to type it.
6. When done, quit the program and `ctx close "<tab>" without asking`, unless the user will want it (a server, a REPL with data loaded); then name it in your reply.

## Program notes

- Python, IPython, pdb: [reference/python.md](reference/python.md)
- gdb, lldb, core files: [reference/native-debuggers.md](reference/native-debuggers.md)
- ssh, sudo, remote tmux: [reference/ssh.md](reference/ssh.md)
- adb shell, logcat: [reference/adb.md](reference/adb.md)
- psql, sqlite3, mysql, redis-cli, node: [reference/databases-and-repls.md](reference/databases-and-repls.md)
- Several tabs at once, job control in a tab, passing variables between tabs: [reference/tabs-and-jobs.md](reference/tabs-and-jobs.md)
