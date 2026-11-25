# -*- coding: utf-8 -*-
"""把 battleskin-090\dist 打成可分发 zip，并生成 SHA256SUMS 校验值。"""
import hashlib
import zipfile
from pathlib import Path

DIST = Path(r"D:\DeepSeek harness\workspace\战争雷霆离线版BUG修复\battleskin-090\dist")
OUT = Path(r"D:\DeepSeek harness\workspace\战争雷霆离线版BUG修复\BattleSkinFix-0.9.0.zip")

ORDER = ["install.ps1", "uninstall.ps1", "说明.txt", "files/gui.vromfs.bin"]


def main() -> int:
    missing = [n for n in ORDER if not (DIST / n).is_file()]
    if missing:
        raise SystemExit("missing: " + ", ".join(missing))

    if OUT.exists():
        OUT.unlink()

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for name in ORDER:
            src = DIST / name
            # 关键：不带 dist\ 这层目录，解压后 install.ps1 直接落在游戏根目录。
            zf.write(src, arcname=name)

    digest = hashlib.sha256(OUT.read_bytes()).hexdigest()
    print(f"zip={OUT}")
    print(f"size={OUT.stat().st_size}")
    print(f"sha256={digest}")

    with zipfile.ZipFile(OUT) as zf:
        print("entries:")
        for info in zf.infolist():
            print(f"  {info.filename}  {info.file_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
