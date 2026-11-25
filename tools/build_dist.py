# -*- coding: utf-8 -*-
"""生成 0.9.0 专用涂装修复包到 battleskin-090\dist。

只替换 gui.vromfs.bin —— 0.9.5 包里的 aces-patched.exe 是 2.61 的二进制，
不能用于 2.59.0.92 客户端，所以本包不含任何 exe 补丁。
"""
import hashlib
import json
import shutil
from pathlib import Path

DIST = Path(r"D:\DeepSeek harness\workspace\战争雷霆离线版BUG修复\battleskin-090\dist")
BUILD = Path(r"D:\DeepSeek harness\workspace\战争雷霆离线版BUG修复\battleskin-090\build")
GAME = Path(r"D:\GameApp\WarThunderOffline")

NEW_GUI = BUILD / "gui.vromfs.bin"
ORIGINAL_GUI = GAME / "client" / "gui.vromfs.bin"
ACES = GAME / "client" / "win64" / "aces.exe"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if DIST.exists():
        shutil.rmtree(DIST)
    files = DIST / "files"
    files.mkdir(parents=True)

    shutil.copy2(NEW_GUI, files / "gui.vromfs.bin")

    new_hash = sha256(NEW_GUI)
    orig_hash = sha256(ORIGINAL_GUI)
    aces_hash = sha256(ACES)
    client_build = json.loads((GAME / "data" / "client-build.json").read_text(encoding="utf-8-sig"))

    manifest = {
        "name": "battle-skin-090",
        "targetClientVersion": "2.59.0.92",
        "description": "对局/机库涂装修复，仅替换 gui.vromfs.bin；不含 exe 补丁。",
        "files": [
            {
                "target": "client/gui.vromfs.bin",
                "source": "gui.vromfs.bin",
                "sha256": new_hash,
                # 允许两种"原版"：当前已装（首次安装）或本来就未改动过。
                "acceptOriginalSHA256": [orig_hash],
                "size": NEW_GUI.stat().st_size,
            }
        ],
        "expectedAcesSHA256": aces_hash,
        "expectedClientVersion": client_build.get("clientVersion", ""),
    }
    (DIST / "patch-manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    (DIST / "SHA256SUMS.txt").write_text(
        f"{new_hash}  files/gui.vromfs.bin\n", encoding="utf-8")

    print(f"dist={DIST}")
    print(f"gui={new_hash} ({NEW_GUI.stat().st_size} bytes)")
    print(f"originalGui={orig_hash}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
