#!/bin/sh
cat > configure <<'PY'
#!/usr/bin/env python3
"""Interactive setup for the billing service."""
import hashlib, json, os, sys

if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit("configure is interactive: run it in a terminal (stdin and stdout must be a TTY).")

def ask(q, default=None, check=None):
    while True:
        a = input(f"{q}{f' [{default}]' if default else ''}: ").strip() or (default or "")
        if not check or check(a):
            return a
        print("  invalid, try again")

print("Billing service setup")
name = ask("Service name", check=lambda a: a.isidentifier())
port = int(ask("Port", "8080", check=lambda a: a.isdigit() and 1 <= int(a) < 65536))
tls = ask("Enable TLS? (y/n)", "n", check=lambda a: a in ("y", "n")) == "y"
email = ask("Admin email", check=lambda a: "@" in a)
print(f"\n  name={name} port={port} tls={tls} admin={email}")
if ask("Write config.json? (y/n)", "y", check=lambda a: a in ("y", "n")) != "y":
    sys.exit("nothing written")
cfg = {"name": name, "port": port, "tls": tls, "admin_email": email}
cfg["wizard_stamp"] = hashlib.sha256(("wizard:" + json.dumps(cfg, sort_keys=True)).encode()).hexdigest()[:16]
json.dump(cfg, open("config.json", "w"), indent=2)
print("wrote config.json")
PY
chmod +x configure
