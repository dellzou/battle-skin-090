"""Pack a gui-source tree into gui.vromfs.bin for the 2.59.0.92 client.

The game's own vromfs tooling is imported read-only from the installation; the
output archive is written inside the session workspace, and the original 256-byte
format trailer is copied from the client's current gui.vromfs.bin.

Usage:
    python pack_gui.py <source_dir> <output.vromfs.bin>
"""
import hashlib
import io
import sys
from pathlib import Path

GAME = Path(r"D:\GameApp\WarThunderOffline")
for rel in ("work/python-libs", "work/vromfs-tool/src", "work/blk-tool/src", str(GAME / "tools")):
    sys.path.insert(0, str(GAME / rel))

import construct as ct

_read, _write, _seek, _tell = ct.stream_read, ct.stream_write, ct.stream_seek, ct.stream_tell
ct.stream_read = lambda stream, length, path="(vromfs)": _read(stream, length, path)
ct.stream_write = lambda stream, data, length=None, path="(vromfs)": _write(
    stream, data, len(data) if length is None else length, path
)
ct.stream_seek = lambda stream, offset, whence=0, path="(vromfs)": _seek(stream, offset, whence, path)
ct.stream_tell = lambda stream, path="(vromfs)": _tell(stream, path)

from vromfs.bin import BinFile, PlatformType
from vromfs.vromfs import VromfsFile
import free_notice_policy

VERSION = (2, 59, 0, 92)
TRAILER_SOURCE = GAME / "client" / "gui.vromfs.bin"


def main() -> int:
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    # 免费声明完整性校验：打包前先过一遍源码树。
    free_notice_policy.verify_tree(source)

    # 原生加载器会把路径统一转小写，大写条目在运行时直接找不到。
    for path in source.rglob("*"):
        name = path.relative_to(source).as_posix()
        if path.is_file() and name != name.lower():
            raise SystemExit("uppercase resource path: " + name)

    image = io.BytesIO()
    VromfsFile.pack_into(source, image)
    size = image.tell()
    image.seek(0)

    payload = io.BytesIO()
    BinFile.pack_into(image, payload, PlatformType.PC, VERSION, True, True, size)
    body = payload.getvalue()

    # 只拷格式尾，不是这份改动包的合法签名（和项目里 Deploy-ProbeResources 一致）。
    trailer = TRAILER_SOURCE.read_bytes()[-256:]
    output.write_bytes(body + trailer)

    # 回读校验：条目数、路径排序、每个文件的 SHA1 都必须和源码一致。
    archive = VromfsFile(BinFile(output))
    encoded = [p.as_posix().encode("utf-8") if p.as_posix() != "nm" else b"\xff?nm"
               for p in archive.meta.names_data]
    if encoded != sorted(encoded):
        raise SystemExit("native full-path binary-search ordering is invalid")
    expected = {p.relative_to(source).as_posix(): p for p in source.rglob("*") if p.is_file()}
    actual = {p.as_posix(): d.hex() for p, d in archive.digests_table().items()}
    if len(expected) != len(actual):
        raise SystemExit(f"file count mismatch {len(expected)} != {len(actual)}")
    for name, path in expected.items():
        if actual.get(name) != hashlib.sha1(path.read_bytes()).hexdigest():
            raise SystemExit("round-trip payload mismatch: " + name)

    print(f"archive={output}")
    print(f"files={len(actual)} bytes={output.stat().st_size}")
    print(f"sha256={hashlib.sha256(output.read_bytes()).hexdigest()}")
    print("verified=entries,padding,sha1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
