# How agents have used ctx (2026-10-11 to 2026-10-23)

Sources: `~/Library/Application Support/ctx/activity.log` (4,432 sentences) and the ctx calls in Claude Code transcripts since 2026-10-11 (49 sessions; 704 calls that wrote `ctx …` or used the old MCP tools, plus every Bash result scanned for ctx's own failure messages). Codex left no transcripts; Antigravity is covered by the activity log only. Scripts: `scratchpad/usage/*.py` in the session that wrote this.

## Who used it

| | Sentences |
|---|---|
| Claude Code | 3,880 |
| You (CLI, CTX.app) | 320 |
| Antigravity | 218 |

Of Claude's 3,880, 1,651 are the Bash hook's `ctx run in "Claude <session>" …` and 1,524 are the hook's own `ctx list tabs` lookup before each of them. What agents wrote themselves is about 1,200 sentences. The old MCP tools were called 492 times, mostly in the YMCA project (`ctx_run` 134, `ctx` 132, `ctx_wait` 63, `ctx_read` 63, `ctx_type` 39, `ctx_press` 34).

What agents reach for, after `run`: `read last N commands as json` (106), `read last N lines` (69), `wait until … shows …` (78), `type … then press enter` (75), `find` (54), `without waiting` (71). Rarely: `ask` (1), `as toon` (1, against 225 `as json`), `read everything` (9).

## Failures, ranked by cost

1. **A busy session tab blocks every later command (open, since 2026-10-21).** The hook sends all of a session's Bash calls to one tab. A `run_in_background` call becomes `without waiting` in that tab, and a foreground call that outlasts the Bash timeout keeps running there. Either way the tab stays busy and each later Bash call fails with `Tab N "Claude 4aa559ca" is running "…"; open another tab`. Found 37 such failures in 230 hooked calls since 10-21; 43 of the busy mentions trace to background starts (`sleep 1800 && …`, `gh run watch`, a crawler), 18 to timed-out foreground commands. The new `ctx mcp` `shell` tool has the same shape. Fix: a background command gets its own tab, and a command for a busy session tab goes to the session's next tab (`Claude 4aa559ca 2`), so the agent never sees "busy" for its own shell.
2. **Claude's working directory and the tab's drift apart (open, found today).** In a hooked session, `cd /Users/c/Workspaces/charles-terminal-experience && pwd` printed `…/charles-terminal-experience/ctx`; the same command run directly with `ctx run in` printed the right folder. Claude Code tracks its own working directory, and with the hook it never changes (the `cd`s happen in the tab), so it apparently treats `cd <its own cwd>` as a no-op and drops it (inferred from behaviour, not confirmed in Claude Code's docs). The command then runs wherever the tab was left, and relative paths silently hit the wrong folder. The Codex, Cursor, pi and opencode hooks already prefix `cd <agent cwd> &&` when it differs from the tab's folder; the Claude hook ignores the `cwd` it's given. Fix: do the same for Claude (and in `ctx mcp`), so the tab always starts where the agent thinks it is.
3. **The hook's lookup floods the activity log.** 1,524 of 1,843 `ctx list tabs` entries (a third of the whole log) are the hook checking that its tab exists. They make `list activity` hard to read and inflate any usage count. Fix: the lookup is a request that isn't logged (or one "ensure session tab" request that is logged once, when it opens the tab).
4. **Local tabs without shell-integration marks (fixed).** 28 failures from 10-11 to 10-20: `run`, `read last command` and `wait … is idle` refused in local tabs because the integration files had been deleted by macOS temp cleanup. Agents worked around it with ~50 calls of `type "…; echo DONE-N"` + `wait until … shows "DONE-N"`. None since `781f5a0` (10-20 12:29). Remaining fix: the message blames ssh or a non-zsh shell even in a local zsh tab; it should say the integration didn't load and how to repair it.
5. **Tab names can't contain `.`** (`Claude - claude.md research` refused, `ctx-server/src/server.rs:3564`). Names with file names and domains are natural. Fix: allow `.` (and probably `:` `/` `@`), keep quotes and control characters out.
6. **A bare number isn't a tab** (`in 298` → "`in` needs a tab"). Names must contain a letter, so a bare number can only mean a tab number. Fix: accept it.
7. **Polling with `sleep`** (5 calls blocked by Claude Code: `sleep N; ctx read …`). `ctx wait` exists and the instructions mention it; low priority.
8. **`wait until <server tab> is idle`** on a dev server (never idle). The error already says it keeps running and how to read it; low priority.
9. **Staged integrations keep deleted files.** `ctx install hooks for claude` rewrote the plugin but left the old `.mcp.json` in `~/Library/Application Support/ctx/integrations/claude`, so the removed MCP server would have kept loading. Removed by hand today; fix: staging clears the folder first.
10. **`help launcher`** has no answer (the verbs are `make`/`list`/`rebuild`/`remove launcher`). Help should accept a noun and list the sentences that use it.

## Data for open decisions

- TOON: agents asked for JSON 225 times and TOON once, unprompted. The eval should still decide, but the default is not trending toward TOON.
- `ask` is almost unused by agents (1 call). Either it isn't advertised where they look, or `find` + `read` is enough.
