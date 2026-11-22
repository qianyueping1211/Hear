#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 desktop/VERSION 同步到 package.json、Cargo.toml 和 tauri.conf.json。"""

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    ver = (ROOT / "desktop" / "VERSION").read_text(encoding="utf-8").strip()
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", ver):
        raise SystemExit("desktop/VERSION 格式不对：%s" % ver)

    for rel in ("desktop/package.json", "desktop/src-tauri/tauri.conf.json"):
        path = ROOT / rel
        obj = json.loads(path.read_text(encoding="utf-8"))
        obj["version"] = ver
        path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    cargo = ROOT / "desktop" / "src-tauri" / "Cargo.toml"
    text = cargo.read_text(encoding="utf-8")
    updated = re.sub(r'(?m)^version = "[^"]+"', 'version = "%s"' % ver, text, count=1)
    cargo.write_text(updated, encoding="utf-8")
    print("Synced desktop version:", ver)


if __name__ == "__main__":
    main()
