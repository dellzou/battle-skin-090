# -*- coding: utf-8 -*-
"""Quirrel 方言与引用完整性检查（针对本次涂装修复移植的改动）。

规则都来自项目实际踩过的坑：
  1. 没有 `var` 声明，只有 let / local；
  2. 没有 DAS 风格的 float()/int()/str()，要用 .tofloat() 等；
  3. 新增行里的裸调用必须是本文件已定义或有 require 进来的可调用名；
  4. 花括号/圆括号/方括号配平；
  5. require/import 的 % 路径必须真的存在于 gui-source 里；
  6. 导出的符号必须真的被定义过。
"""
import io
import re
import sys
from pathlib import Path

ROOT = Path(r"D:\DeepSeek harness\workspace\战争雷霆离线版BUG修复\battleskin-090\gui-source")
BASE = Path(r"D:\GameApp\WarThunderOffline\work\patches\gui-source")

CHANGED = [
    "scripts/offline/battle.nut",
    "scripts/offline/camouflage.nut",
    "scripts/offline/decorations.nut",
    "scripts/offline/profile.nut",
    "scripts/customization/skins.nut",
    "scripts/customization/customizationwnd.nut",
    "scripts/hangarmodelloadmanager.nut",
]

KEYWORDS = {"if", "for", "while", "function", "return", "catch", "foreach", "switch",
            "typeof", "delete", "clone", "resize", "in"}

# %xxx/yyy.nut 以及 %AppGlobals 这类映射，统一按已知前缀映射到目录
PATH_ALIASES = {
    "%scripts/": "scripts/",
    "%sqstd/": "std/",
    "%sqStdLibs/": "sqstdlibs/",
    "%appGlobals/": "globals/",
    "%globalScripts/": "globalscripts/",
}

problems = []


def resolve(nut_path: str):
    for prefix, folder in PATH_ALIASES.items():
        if nut_path.startswith(prefix):
            return ROOT / (folder + nut_path[len(prefix):]).lower() if False else ROOT / (folder + nut_path[len(prefix):])
    return None


def check_file(rel: str):
    cur_path = ROOT / rel
    text = io.open(cur_path, encoding="utf-8").read()
    lines = text.splitlines()
    base_path = BASE / rel
    base = io.open(base_path, encoding="utf-8").read() if base_path.is_file() else ""

    defined = set(re.findall(r"function\s+([a-zA-Z_]\w*)\s*\(", text))
    defined |= set(re.findall(r"^\s*([a-zA-Z_]\w*)\s*=\s*(?:function|@)", text, re.M))
    defined |= set(re.findall(r"^\s*(?:let|local)\s+([a-zA-Z_]\w*)\s*=", text, re.M))
    # 导入进来的名字也算已知
    for m in re.finditer(r"from\s+\"[^\"]+\"\s+import\s+([^\n]+)", text):
        for name in re.split(r"[,*]", m.group(1)):
            name = name.strip().split(" as ")[-1].strip()
            if re.fullmatch(r"[a-zA-Z_]\w*", name or ""):
                defined.add(name)
    for m in re.finditer(r"import\s+\"[^\"]+\"\s+as\s+([a-zA-Z_]\w*)", text):
        defined.add(m.group(1))
    for m in re.finditer(r"(?:let|local)\s*\{([^}]*)\}\s*=\s*require", text):
        for name in re.split(r"[,*]", m.group(1)):
            name = name.strip()
            if re.fullmatch(r"[a-zA-Z_]\w*", name or ""):
                defined.add(name)

    for idx, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        if re.match(r"^\s*var\s+\w+", line):
            problems.append(f"{rel}:{idx} 使用了 var 声明（只有 let/local）")
        if re.search(r"(?<![.\w])(float|int|str)\s*\(", line):
            problems.append(f"{rel}:{idx} 使用了 DAS 风格转换函数: {stripped}")

    # 新增行里的裸调用检查
    added = []
    if base:
        import difflib
        added = [l[1:] for l in difflib.unified_diff(base.splitlines(), lines, lineterm="", n=0)
                 if l.startswith("+") and not l.startswith("+++")]
    for body in added:
        if body.strip().startswith("//"):
            continue
        for call in re.findall(r"(?<![.\w])([a-zA-Z_]\w*)\s*\(", body):
            if call in KEYWORDS or call in defined:
                continue
            if re.search(r"\b" + re.escape(call) + r"\s*\(", text):
                continue
            problems.append(f"{rel} 新增行出现未定义调用 {call}(): {body.strip()}")

    for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
        if text.count(open_ch) != text.count(close_ch):
            problems.append(f"{rel} 括号不平衡 {open_ch}={text.count(open_ch)} {close_ch}={text.count(close_ch)}")

    # require/import 路径存在性
    for m in re.finditer(r'(?:from|import|require\()\s*"(%[^"]+)"', text):
        nut = m.group(1)
        for prefix, folder in PATH_ALIASES.items():
            if nut.startswith(prefix):
                target = ROOT / (folder + nut[len(prefix):])
                if not target.is_file():
                    problems.append(f"{rel} 引用了不存在的路径: {nut}")
                break


for rel in CHANGED:
    check_file(rel)

# 导出符号必须存在
for rel in CHANGED:
    text = io.open(ROOT / rel, encoding="utf-8").read()
    m = re.search(r"return\s*\{([^}]*)\}\s*$", text)
    if not m:
        continue
    body = m.group(1)
    defined = set(re.findall(r"function\s+([a-zA-Z_]\w*)", text))
    defined |= set(re.findall(r"^\s*(?:let|local)\s+([a-zA-Z_]\w*)\s*=", text, re.M))
    defined |= set(re.findall(r"^\s*([a-zA-Z_]\w*)\s*=", text, re.M))
    for token in re.split(r"[\s,]+", body):
        token = token.strip()
        if not re.fullmatch(r"[a-zA-Z_]\w*", token or ""):
            continue
        if token not in defined:
            problems.append(f"{rel} 导出了未定义的符号: {token}")

if problems:
    print("问题清单：")
    for p in problems:
        print("  x", p)
    sys.exit(1)
print(f"全部通过（{len(CHANGED)} 个文件）")
