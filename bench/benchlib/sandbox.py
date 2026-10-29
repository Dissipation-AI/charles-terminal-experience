"""A fresh, isolated folder per run and a sandbox that keeps the agent inside it: a Seatbelt
profile on macOS, bubblewrap on Linux.

The agent sees only its run folder: a fake HOME (its own agent config and credentials copy), the
task's working folder, a bin/ folder with the tools the setup provides, and TMPDIR. It can't read
the real home folder (so no source code, notes, agent configs or memories), other runs, or other
programs' files in /tmp. Network is allowed: the agent has to reach its model.
"""
import json
import os
import secrets
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

LINUX = os.uname().sysname == "Linux"
ROOT = Path("/tmp/ab" if LINUX else "/private/tmp/ab")  # neutral name: the path is visible to the agent
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
        root.with_suffix(".run").mkdir()
        rd = cls(root, workname)
        # A login shell (ctx opens tabs in the user's login shell) resets PATH from /etc/profile
        # on Debian, where macOS's path_helper keeps it. A user's own profile puts their tools back
        # on PATH; this one does the same for the run's bin/.
        line = f'export PATH="{rd.bin}:$PATH"\n'
        for f in (".profile", ".bash_profile", ".zprofile"):
            (rd.home / f).write_text(line)
        return rd

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
    def private(self) -> Path:
        """The harness's own files for the run (driver, transcript, plugin sources), beside the run
        folder rather than in it, so the agent doesn't come across them while looking around."""
        return self.root.with_suffix(".run")

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
        if LINUX:
            return self._write_bwrap()
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
            f"(allow file-read* file-write* (subpath {q(self.root)}) (subpath {q(self.private)}))",
            # No keychain: agy's keyring library runs `security`, which puts a dialog on the
            # user's screen. Denied, agy falls back to its token file at once.
            '(deny process-exec (literal "/usr/bin/security"))',
            '(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.security.agent"))',
            # Network and automounted volumes: a search of / (`grep -r`, `find`) reaches /home and
            # /net (autofs), and macOS then asks the user, on the run's behalf, to allow access to
            # "files on a network volume". Denied here, the search gets an error and no dialog.
            *[f"(deny file-read* file-write* (subpath {q(p)}))" for p in
              ("/Volumes", "/Network", "/net", "/home", "/System/Volumes/Data/home")],
            # /tmp itself is a symlink every program resolves.
            '(allow file-read* (literal "/tmp") (literal "/private"))',
        ]
        self.profile_path.write_text("\n".join(lines) + "\n")
        return self.profile_path

    def _write_bwrap(self) -> Path:
        """bubblewrap arguments: the system read-only, and empty /home and /tmp with only the run
        folder, the harness's files beside it and the readable paths put back. Its own pid
        namespace: `ps` shows the run's processes, not the harness or the rest of the machine (which
        made agents go looking into the harness). Everything in it ends when the driver exits, so
        the driver waits for the harness to release it after check.sh."""
        args = ["--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev", "--unshare-pid", "--proc", "/proc"]
        for p in ("/home", "/tmp", "/var/tmp", "/dev/shm", "/run/user", "/mnt", "/media"):
            if os.path.isdir(p):
                args += ["--tmpfs", p]
        for p in sorted(set(self.readable)):
            args += ["--ro-bind", str(p), str(p)]
        args += ["--bind", str(self.root), str(self.root), "--bind", str(self.private), str(self.private)]
        self.profile_path.write_text(json.dumps(args, indent=0) + "\n")
        return self.profile_path

    def cmd(self, argv: list[str]) -> list[str]:
        if LINUX:
            return ["bwrap", *json.loads(self.profile_path.read_text()), "--", *argv]
        return ["sandbox-exec", "-f", str(self.profile_path), *argv]

    def popen(self, argv, env=None, cwd=None, **kw) -> subprocess.Popen:
        if LINUX:
            # Arguments through a file descriptor, so bwrap's command line (pid 1 in the sandbox,
            # visible to `ps`) doesn't list the harness's paths.
            r, w = os.pipe()
            os.write(w, b"".join(a.encode() + b"\0" for a in json.loads(self.profile_path.read_text())))
            os.close(w)
            try:
                return subprocess.Popen(["bwrap", "--args", str(r), "--", *argv], env=env or self.env(),
                                        cwd=cwd or self.work, pass_fds=(r,), **kw)
            finally:
                os.close(r)
        return subprocess.Popen(self.cmd(argv), env=env or self.env(), cwd=cwd or self.work, **kw)

    def run(self, argv, env=None, cwd=None, timeout=120, **kw) -> subprocess.CompletedProcess:
        return subprocess.run(
            self.cmd(argv), env=env or self.env(), cwd=cwd or self.work, timeout=timeout,
            capture_output=True, text=True, **kw,
        )

    def kill_leftovers(self):
        """Kill every process still using the run folder (servers the agent left running, tabs)."""
        pids = set()
        for d in (self.root, self.private):
            out = subprocess.run(["lsof", "-t", "+D", str(d)], capture_output=True, text=True).stdout
            pids |= {int(p) for p in out.split() if p.strip().isdigit()}
        pids -= {os.getpid()}
        for pid in pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        return len(pids)

    def remove(self):
        shutil.rmtree(self.root, ignore_errors=True)
        shutil.rmtree(self.private, ignore_errors=True)
        self.profile_path.unlink(missing_ok=True)
