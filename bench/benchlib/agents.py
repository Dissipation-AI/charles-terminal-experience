"""Agent adapters: how to give an agent its credentials, install a setup's components the way a
user would, run it headless on one prompt, and turn its transcript into numbers.

Adding an agent means adding a class here with the same methods and registering it in AGENTS.
"""
import json
import os
import re
import shutil
import subprocess
from collections import Counter
from pathlib import Path

from .sandbox import RunDir


def _version(argv) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as e:
        return f"unknown ({e})"


CTX_WORD = re.compile(r"(^|[;&|(]\s*|\s)ctx\s")


def wrote_ctx(command: str) -> bool:
    """The agent itself wrote a ctx sentence (as opposed to the hook rewriting its command)."""
    return bool(CTX_WORD.search(command or ""))


def skills_referenced(text: str, skills: list[str]) -> list[str]:
    """Skills whose folder a tool call touched (reading SKILL.md or a reference file)."""
    return [s for s in skills if re.search(rf"(?<![\w-]){re.escape(s)}(?![\w-])", text)]


RESETS = re.compile(r"resets? in (?:(\d+)h)?\s*(?:(\d+)m)?\s*(?:(\d+)s)?", re.I)


def quota_reset_seconds(text: str) -> int | None:
    """Seconds until a quota resets, when the error says so ("Resets in 1h17m28s")."""
    m = RESETS.search(text or "")
    if not m or not any(m.groups()):
        return None
    h, mi, se = (int(g or 0) for g in m.groups())
    return h * 3600 + mi * 60 + se


def _infra(markers, parsed: dict, stderr: str) -> str | None:
    """An error that says nothing about the setup. A quota or overload error ends the run whenever
    it hits, so it counts even after tool calls; the run is retried rather than scored as a fail."""
    text = f"{parsed.get('agent_error') or ''} {stderr}".lower()
    for marker in markers:
        if marker in text:
            return marker
    return None


class Agy:
    """Google Antigravity CLI (`agy`)."""

    name = "agy"
    exe = shutil.which("agy") or str(Path.home() / ".local/bin/agy")
    token = Path.home() / ".gemini/antigravity-cli/antigravity-oauth-token"
    ctx_agent = "antigravity"  # the name ctx's installer and hook use

    def version(self) -> str:
        return _version([self.exe, "--version"])

    def prepare(self, rd: RunDir):
        rd.link_tool("agy", self.exe)
        cli = rd.home / ".gemini/antigravity-cli"
        cli.mkdir(parents=True)
        shutil.copy2(self.token, cli / self.token.name)
        return {"AGY_CLI_DISABLE_AUTO_UPDATE": "1"}  # the version is pinned by hand; runs record it

    def install_commands(self, rd: RunDir, setup: dict) -> list[list[str]]:
        cmds = []
        if setup.get("ctx"):
            cmds.append(["ctx", "install", "hooks", "for", self.ctx_agent])
        for plugin in setup.get("plugins", []):
            cmds.append(["agy", "plugin", "install", plugin])
        return cmds

    def command(self, prompt: str, model: str, timeout: int, setup: dict, task: dict | None = None) -> list[str]:
        return [
            "agy", "-p", prompt, "--model", model, "--output-format", "stream-json",
            "--dangerously-skip-permissions", "--print-timeout", f"{timeout}s",
        ]

    def parse(self, transcript: Path, skills: list[str]) -> dict:
        tools, shell, skill_hits, result, init = Counter(), 0, Counter(), {}, {}
        errors, ctx_cmds = [], 0
        for line in transcript.read_text(errors="replace").splitlines():
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("event") == "init":
                init = ev.get("init", {})
            elif ev.get("event") == "result":
                result = ev.get("result", {})
            elif ev.get("event") == "step_update":
                st = ev["step_update"]
                if st.get("step_type") == "tool" and st.get("state") == "DONE":
                    name = st.get("tool_name") or "?"
                    tools[name] += 1
                    params = json.dumps(st.get("tool_info", {}).get("parameters", {}))
                    if name in ("run_command", "send_command_input"):
                        shell += 1
                        ctx_cmds += wrote_ctx(st.get("tool_info", {}).get("parameters", {}).get("CommandLine", ""))
                    for s in skills_referenced(params, skills):
                        skill_hits[s] += 1
                if st.get("state") == "ERROR":
                    errors.append(st.get("error") or st.get("text_delta") or "step error")
        usage = result.get("usage", {})
        return {
            "agent_status": result.get("status"),
            "agent_error": result.get("error"),
            "conversation_id": result.get("conversation_id") or init.get("conversation_id"),
            "model_reported": init.get("model"),
            "agent_seconds": result.get("duration_seconds"),
            "turns": result.get("num_turns"),
            "tokens": {
                "input": usage.get("input_tokens", 0),
                "output": usage.get("output_tokens", 0),
                "thinking": usage.get("thinking_tokens", 0),
                "cache_read": usage.get("cache_read_tokens", 0),
                "cache_write": 0,
                "total": usage.get("total_tokens", 0),
            },
            "cost_usd": None,
            "tool_calls": dict(tools),
            "tool_calls_total": sum(tools.values()),
            "shell_calls": shell,
            "shell_calls_writing_ctx": ctx_cmds,
            "skill_reads": dict(skill_hits),
            "step_errors": errors[:20],
            "response": result.get("response", ""),
        }

    def infra_error(self, parsed: dict, stderr: str) -> str | None:
        """An error that says nothing about the setup (quota, network, auth): retry later."""
        return _infra(("429", "resource_exhausted", "quota", "rate limit", "unavailable", "503",
                       "unauthenticated", "not logged in", "deadline exceeded", "connection reset"), parsed, stderr)


class Claude:
    """Claude Code (`claude`). Auth comes from a long-lived token (`claude setup-token`) saved in
    the file below, so a run never touches the user's own login or the keychain."""

    name = "claude"
    exe = shutil.which("claude") or str(Path.home() / ".local/bin/claude")
    token_file = Path.home() / ".config/ctx-bench/claude-oauth-token"
    ctx_agent = "claude"

    def version(self) -> str:
        return _version([self.exe, "--version"])

    def _token(self) -> str:
        if not self.token_file.exists():
            raise RuntimeError(
                f"no Claude token: run `claude setup-token` and save the token it prints in {self.token_file}"
                " (chmod 600)")
        return self.token_file.read_text().strip()

    def prepare(self, rd: RunDir):
        rd.link_tool("claude", self.exe)
        cfg = rd.home / ".claude"
        cfg.mkdir(parents=True)
        # Skip the first-run screens; nothing else carries over from the user's config.
        (rd.home / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True}))
        return {"CLAUDE_CODE_OAUTH_TOKEN": self._token(), "CLAUDE_CONFIG_DIR": str(cfg),
                "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}

    def install_commands(self, rd: RunDir, setup: dict) -> list[list[str]]:
        cmds = []
        if setup.get("ctx"):
            cmds.append(["ctx", "install", "hooks", "for", self.ctx_agent])
        return cmds

    def command(self, prompt: str, model: str, timeout: int, setup: dict, task: dict | None = None) -> list[str]:
        argv = ["claude", "-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
                "--permission-mode", "bypassPermissions", "--no-session-persistence"]
        for plugin in setup.get("plugins", []):
            argv += ["--plugin-dir", plugin]
        return argv

    def parse(self, transcript: Path, skills: list[str]) -> dict:
        tools, shell, skill_hits, result, init = Counter(), 0, Counter(), {}, {}
        ctx_cmds = 0
        for line in transcript.read_text(errors="replace").splitlines():
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "system" and ev.get("subtype") == "init":
                init = ev
            elif ev.get("type") == "result":
                result = ev
            elif ev.get("type") == "assistant":
                for block in ev.get("message", {}).get("content", []):
                    if block.get("type") != "tool_use":
                        continue
                    name = block.get("name", "?")
                    tools[name] += 1
                    if name in ("Bash", "mcp__ctx__shell"):
                        shell += 1
                        ctx_cmds += wrote_ctx(block.get("input", {}).get("command", ""))
                    for s in skills_referenced(json.dumps(block.get("input", {})), skills):
                        skill_hits[s] += 1
        u = result.get("usage", {})
        tin = u.get("input_tokens", 0)
        return {
            "agent_status": "SUCCESS" if result.get("subtype") == "success" and not result.get("is_error") else "ERROR",
            "agent_error": result.get("result") if result.get("is_error") else None,
            "conversation_id": result.get("session_id") or init.get("session_id"),
            "model_reported": init.get("model"),
            "agent_version_reported": init.get("claude_code_version"),
            "skills_available": init.get("skills"),
            "plugins_loaded": init.get("plugins"),
            "agent_seconds": (result.get("duration_ms") or 0) / 1000,
            "api_seconds": (result.get("duration_api_ms") or 0) / 1000,
            "turns": result.get("num_turns"),
            "tokens": {
                "input": tin,
                "output": u.get("output_tokens", 0),
                "thinking": (u.get("output_tokens_details") or {}).get("thinking_tokens", 0),
                "cache_read": u.get("cache_read_input_tokens", 0),
                "cache_write": u.get("cache_creation_input_tokens", 0),
                "total": tin + u.get("output_tokens", 0) + u.get("cache_read_input_tokens", 0)
                + u.get("cache_creation_input_tokens", 0),
            },
            "cost_usd": result.get("total_cost_usd"),
            "tool_calls": dict(tools),
            "tool_calls_total": sum(tools.values()),
            "shell_calls": shell,
            "shell_calls_writing_ctx": ctx_cmds,
            "skill_reads": dict(skill_hits),
            "permission_denials": len(result.get("permission_denials") or []),
            "response": result.get("result", ""),
        }

    def infra_error(self, parsed: dict, stderr: str) -> str | None:
        return _infra(("rate limit", "overloaded", "529", "not logged in", "invalid api key", "usage limit",
                       "connection error"), parsed, stderr)


class Oracle:
    """Runs the task's reference solution (tasks/<task>/solve.sh) instead of a model: checks the
    harness, the sandbox and every task's check without spending tokens."""

    name = "oracle"
    ctx_agent = None

    def version(self) -> str:
        return "oracle 1"

    def prepare(self, rd: RunDir):
        return {}

    def install_commands(self, rd: RunDir, setup: dict) -> list[list[str]]:
        return []

    def command(self, prompt: str, model: str, timeout: int, setup: dict, task: dict | None = None) -> list[str]:
        script = (task["dir"] / "solve.sh").read_text()
        return ["/bin/sh", "-c", f'out=$( ( {script}\n) 2>&1); st=$?; '
                'python3 -c \'import json,sys; print(json.dumps({"exit": int(sys.argv[1]), "out": sys.argv[2]}))\' '
                '"$st" "$out"']

    def parse(self, transcript: Path, skills: list[str]) -> dict:
        lines = transcript.read_text().strip().splitlines()
        r = json.loads(lines[-1]) if lines else {}
        return {"agent_status": "SUCCESS" if r.get("exit") == 0 else "ERROR", "agent_error": None,
                "turns": 0, "tokens": {k: 0 for k in ("input", "output", "thinking", "cache_read", "cache_write", "total")},
                "cost_usd": 0, "tool_calls": {}, "tool_calls_total": 0, "shell_calls": 0, "skill_reads": {},
                "response": r.get("out", "")}

    def infra_error(self, parsed: dict, stderr: str) -> str | None:
        return None


AGENTS = {a.name: a for a in (Agy(), Claude(), Oracle())}
