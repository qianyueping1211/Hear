#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 apps/desktop/VERSION 同步到 package.json、Cargo.toml 和 tauri.conf.json。"""

import json
import pathlib
import re

DESKTOP_DIR = pathlib.Path(__file__).resolve().parent.parent


def main():
    ver = (DESKTOP_DIR / "VERSION").read_text(encoding="utf-8").strip()
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", ver):
        raise SystemExit("apps/desktop/VERSION 格式不对：%s" % ver)

    for rel in ("package.json", "src-tauri/tauri.conf.json"):
        path = DESKTOP_DIR / rel
        obj = json.loads(path.read_text(encoding="utf-8"))
        obj["version"] = ver
        path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    cargo = DESKTOP_DIR / "src-tauri" / "Cargo.toml"
    text = cargo.read_text(encoding="utf-8")
    updated = re.sub(r'(?m)^version = "[^"]+"', 'version = "%s"' % ver, text, count=1)
    cargo.write_text(updated, encoding="utf-8")
    print("Synced desktop version:", ver)


if __name__ == "__main__":
    main()
