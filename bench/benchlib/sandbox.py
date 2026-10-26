"""A fresh, isolated folder per run and a seatbelt profile that keeps the agent inside it.

The agent sees only its run folder: a fake HOME (its own agent config and credentials copy), the
task's working folder, a bin/ folder with the tools the setup provides, and TMPDIR. It can't read
the real home folder (so no source code, notes, agent configs or memories), other runs, or other
programs' files in /tmp. Network is allowed: the agent has to reach its model.
"""
import os
import secrets
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path("/private/tmp/ab")  # neutral name: the path is visible to the agent
REAL_HOME = Path(os.path.realpath(Path.home()))
BASE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def _ancestors(p: Path) -> list[Path]:
    return [a for a in p.parents if a != Path("/")]


@dataclass
class RunDir:
    root: Path
    workname: str
    readable: list[Path] = field(default_factory=list)  # outside paths the agent may read

    @classmethod
    def create(cls, workname: str) -> "RunDir":
        ROOT.mkdir(parents=True, exist_ok=True)
        root = ROOT / secrets.token_hex(4)
        for d in ("home", "bin", "tmp", workname):
            (root / d).mkdir(parents=True)
        return cls(root, workname)

    @property
    def home(self) -> Path:
        return self.root / "home"

    @property
    def work(self) -> Path:
        return self.root / self.workname

    @property
    def bin(self) -> Path:
        return self.root / "bin"

    @property
    def ctx_home(self) -> Path:
        return self.root / ".ctx"

    @property
    def profile_path(self) -> Path:
        # Next to the run folder, not in it: the agent can't read (or change) its own sandbox.
        return self.root.with_suffix(".sb")

    def link_tool(self, name: str, target: str | Path):
        """Put an outside executable on the agent's PATH and let the sandbox read it."""
        real = Path(os.path.realpath(target))
        (self.bin / name).symlink_to(real)
        self.readable.append(real)

    def env(self, extra: dict | None = None) -> dict:
        env = {
            "HOME": str(self.home),
            "USER": os.environ.get("USER", ""),
            "LOGNAME": os.environ.get("USER", ""),
            "SHELL": "/bin/zsh",
            "TMPDIR": str(self.root / "tmp") + "/",
            "PATH": f"{self.bin}:{BASE_PATH}",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
        }
        env.update(extra or {})
        return env

    def write_profile(self) -> Path:
        q = lambda p: '"' + str(p).replace('"', '\\"') + '"'
        meta = sorted({a for p in self.readable if p.is_relative_to(REAL_HOME) for a in [p, *_ancestors(p)]})
        lines = [
            "(version 1)",
            "(allow default)",
            f"(deny file-read* file-write* (subpath {q(REAL_HOME)}))",
            # Programs (SQLite among them) stat each folder above a path they open.
            *[f"(allow file-read-metadata (literal {q(a)}))" for a in meta],
            *[f"(allow file-read* (literal {q(p)}))" for p in self.readable],
            '(deny file-read* file-write* (subpath "/private/tmp"))',
            *[f"(allow file-read-metadata (literal {q(a)}))" for a in ["/private/tmp", ROOT]],
            f"(allow file-read* file-write* (subpath {q(self.root)}))",
            # No keychain: agy's keyring library runs `security`, which puts a dialog on the
            # user's screen. Denied, agy falls back to its token file at once.
            '(deny process-exec (literal "/usr/bin/security"))',
            '(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.security.agent"))',
            # /tmp itself is a symlink every program resolves.
            '(allow file-read* (literal "/tmp") (literal "/private"))',
        ]
        self.profile_path.write_text("\n".join(lines) + "\n")
        return self.profile_path

    def cmd(self, argv: list[str]) -> list[str]:
        return ["sandbox-exec", "-f", str(self.profile_path), *argv]

    def popen(self, argv, env=None, cwd=None, **kw) -> subprocess.Popen:
        return subprocess.Popen(self.cmd(argv), env=env or self.env(), cwd=cwd or self.work, **kw)

    def run(self, argv, env=None, cwd=None, timeout=120, **kw) -> subprocess.CompletedProcess:
        return subprocess.run(
            self.cmd(argv), env=env or self.env(), cwd=cwd or self.work, timeout=timeout,
            capture_output=True, text=True, **kw,
        )

    def kill_leftovers(self):
        """Kill every process still using the run folder (servers the agent left running, tabs)."""
        out = subprocess.run(["lsof", "-t", "+D", str(self.root)], capture_output=True, text=True).stdout
        pids = {int(p) for p in out.split() if p.strip().isdigit()} - {os.getpid()}
        for pid in pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        return len(pids)

    def remove(self):
        shutil.rmtree(self.root, ignore_errors=True)
        self.profile_path.unlink(missing_ok=True)
