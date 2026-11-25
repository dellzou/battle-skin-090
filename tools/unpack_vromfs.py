"""Unpack a .vromfs.bin into a directory using the game's bundled vromfs tool.

Usage:
    python unpack_vromfs.py <container.vromfs.bin> <out_dir>
"""
import sys
from pathlib import Path

GAME = Path(r"D:\GameApp\WarThunderOffline")
for rel in ("work/python-libs", "work/vromfs-tool/src", "work/blk-tool/src"):
    sys.path.insert(0, str(GAME / rel))

import construct as ct

_read, _write, _seek, _tell = ct.stream_read, ct.stream_write, ct.stream_seek, ct.stream_tell
ct.stream_read = lambda stream, length, path="(vromfs)": _read(stream, length, path)
ct.stream_write = lambda stream, data, length=None, path="(vromfs)": _write(
    stream, data, len(data) if length is None else length, path
)
ct.stream_seek = lambda stream, offset, whence=0, path="(vromfs)": _seek(stream, offset, whence, path)
ct.stream_tell = lambda stream, path="(vromfs)": _tell(stream, path)

from blk import Format
from vromfs.bin import BinFile
from vromfs.vromfs import VromfsFile


def main() -> int:
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    with src.open("rb") as fh:
        vromfs = VromfsFile(BinFile(fh))
        names = list(vromfs.name_list)
        failed = 0
        for result in vromfs.unpack_iter(names, out, Format.JSON, False, False):
            if result.error is not None:
                failed += 1
                print(f"[FAIL] {result.path}: {result.error}")
    print(f"unpacked {len(names) - failed}/{len(names)} into {out}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
