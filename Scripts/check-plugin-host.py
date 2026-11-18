#!/usr/bin/env python3
"""Keeps Herm's Desktop plugin host honest.

`sdk/` is built locally and git-ignored; checks 1 and 2 run only where it has been built.

1. `sdk-exports.json` is what `sdk/sdk.js` exports. Swift's compatibility check reads the
   manifest, so a hand edit would let Herm open a plugin whose imports fail to link.
2. Every module host.html and its import map name exists in `sdk/`.
3. The CSP hash in `host.html` matches its inline import map, or WebKit refuses to run it.
"""
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

HOST = Path(__file__).resolve().parent.parent / "Sources/Herm/Resources/DesktopPluginHost"


def module_exports(source: str) -> set[str]:
    """Names in a bundled module's `export{a as B,c}` statements."""
    names = set()
    for group in re.findall(r"export\s*\{([^}]*)\}", source):
        for spec in group.split(","):
            words = spec.split()
            if words:
                names.add(words[-1])
    return names - {"default"}


def main() -> int:
    problems = []
    rebuild = "run Scripts/build-desktop-plugin-host.sh"
    manifest = set(json.loads((HOST / "sdk-exports.json").read_text()))
    sdk = HOST / "sdk/sdk.js"
    built = sdk.exists()
    if built and manifest != module_exports(sdk.read_text()):
        problems.append(f"sdk-exports.json does not match sdk/sdk.js; {rebuild}")

    html = (HOST / "host.html").read_text()
    importmap = re.search(r'<script type="importmap">(.*?)</script>', html, re.S)
    declared = re.search(r"'sha256-([A-Za-z0-9+/=]+)'", html)
    if not importmap or not declared:
        problems.append("host.html needs an inline import map and a sha256 script-src hash")
    else:
        digest = base64.b64encode(hashlib.sha256(importmap.group(1).encode()).digest()).decode()
        if digest != declared.group(1):
            problems.append(f"host.html CSP hash is stale; the import map hashes to 'sha256-{digest}'")
        targets = list(json.loads(importmap.group(1))["imports"].values())
        targets += re.findall(r'(?:src|href)="(/sdk/[^"]+)"', html)
        problems += [] if not built else [f"host.html names {t}, which is not in the bundle" for t in targets if not (HOST / t[1:]).exists()]

    for problem in problems:
        print(f"plugin-host: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    assert module_exports("var a;export{a as B,c,d as default};") == {"B", "c"}
    sys.exit(main())
