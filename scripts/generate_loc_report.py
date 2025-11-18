#!/usr/bin/env python3
"""LOC report generator for StarryOS.

- Outputs loc.json, loc.md，若指定 --comment-output，内容与 loc.md 相同，便于直接贴到评论。
- 仓库按 LOC 降序展示。
"""

import argparse
import json
import subprocess
from pathlib import Path
from typing import Dict, Tuple, List

DEFAULT_EXCLUDES = ["target", ".git", "arceos/target", "build", "dist"]

# --------------------------
# 参数解析
# --------------------------
def parse_args():
    parser = argparse.ArgumentParser(description="StarryOS LOC report generator")

    parser.add_argument("--workspace", required=True)
    parser.add_argument("--clone-dir", required=True)
    parser.add_argument("--output", required=True)

    parser.add_argument(
        "--comment-output",
        required=False,
        help="Write a short summary for GitHub comments",
    )

    parser.add_argument("--top", type=int, default=100, help="Top-N languages per repo (default: 100)")

    return parser.parse_args()


# --------------------------
# 调用 tokei
# --------------------------
def run_tokei(path: Path, excludes: List[str] = None) -> Dict:
    excludes = (excludes or []) + DEFAULT_EXCLUDES
    try:
        cmd = ["tokei", path.as_posix(), "--output", "json"]
        for ex in excludes:
            cmd.extend(["--exclude", ex])
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except Exception as e:
        return {"error": str(e)}


# --------------------------
# 汇总统计
# --------------------------
def summarize_langs(data: Dict) -> Tuple[int, Dict[str, int]]:
    if "error" in data:
        return 0, {}

    langs = {
        k: v.get("code", 0)
        for k, v in data.items()
        if k.lower() != "total"  # tokei 会包含汇总行，需去重
    }
    total = sum(langs.values())
    return total, langs


# --------------------------
# Markdown 表格生成
# --------------------------
def md_table(lang_totals: Dict[str, int], total: int, limit: int) -> str:
    if not lang_totals or total == 0:
        return "_无数据_"

    rows = []
    for lang, loc in sorted(lang_totals.items(), key=lambda kv: kv[1], reverse=True)[:limit]:
        pct = loc / total * 100
        rows.append(f"| {lang} | {loc:,} | {pct:.2f}% |")

    header = "| 语言 | LOC | 占比 |\n|------|------:|------:|"
    return "\n".join([header] + rows)

# --------------------------
# 主逻辑
# --------------------------
def main():
    args = parse_args()

    workspace = Path(args.workspace)
    clone_dir = Path(args.clone_dir)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # 需要统计的 repo 列表：主仓 + local_crates（clone_dir）下每个子目录
    repos: List[Path] = [workspace]
    if clone_dir.exists():
        repos += sorted([p for p in clone_dir.iterdir() if p.is_dir()], key=lambda p: p.name.lower())

    results = {}

    # -------- 扫描仓库 --------
    for repo in repos:
        print(f"[tokei] scanning {repo}")
        # 如果 repo 是 workspace 且 clone_dir 在其中，避免重复统计 local_crates
        if repo == workspace and clone_dir.exists() and clone_dir.is_dir():
            excludes = ["local_crates"]
        else:
            excludes = []
        raw = run_tokei(repo, excludes=excludes)
        total, langs = summarize_langs(raw)

        results[repo.name] = {
            "raw": raw,
            "summary": {
                "total": total,
                "languages": langs,
            },
        }

    # -------- 写 loc.json --------
    with open(output_dir / "loc.json", "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    # -------- 全局汇总 --------
    total_all = sum(r["summary"]["total"] for r in results.values())
    global_langs: Dict[str, int] = {}
    for item in results.values():
        for lang, loc in item["summary"]["languages"].items():
            global_langs[lang] = global_langs.get(lang, 0) + loc

    # -------- repo 排序（按 LOC 降序）--------
    sorted_repos = sorted(results.items(), key=lambda kv: kv[1]["summary"]["total"], reverse=True)

    # -------- 写 loc.md--------
    md_lines = []

    md_lines.append("# StarryOS 代码统计报告")
    md_lines.append("")
    md_lines.append(f"**总计代码行数：{total_all:,} 行**")
    md_lines.append("")

    # 全局语言分布
    md_lines.append("## 全局语言分布（Top 10）")
    md_lines.append(md_table(global_langs, total_all, limit=10))
    md_lines.append("")

    # 仓库排行
    md_lines.append("## 仓库代码排行（按 LOC 降序）")
    md_lines.append("| 仓库 | 总 LOC | Top 语言 |")
    md_lines.append("|------|-------:|----------|")

    for name, entry in sorted_repos:
        total = entry["summary"]["total"]
        langs = entry["summary"]["languages"]
        if total == 0:
            top_lang_desc = "-"
        else:
            top_lang = sorted(langs.items(), key=lambda kv: kv[1], reverse=True)[:3]
            top_lang_desc = ", ".join([f"{k}({v*100/total:.1f}%)" for k, v in top_lang])

        md_lines.append(f"| {name} | {total:,} | {top_lang_desc} |")

    md_lines.append("")

    # 每仓库详细报告
    for name, entry in sorted_repos:
        md_lines.append(f"## {name}")
        if "error" in entry["raw"]:
            md_lines.append(f"⚠ Error scanning repo: {entry['raw']['error']}")
            md_lines.append("")
            continue

        total = entry["summary"]["total"]
        langs = entry["summary"]["languages"]

        md_lines.append(f"- 总 LOC：**{total:,} 行**")
        md_lines.append("")
        md_lines.append("### 语言分布")
        md_lines.append(md_table(langs, total, limit=args.top))
        md_lines.append("")

    final_md = "\n".join(md_lines)
    (output_dir / "loc.md").write_text(final_md, encoding="utf-8")

    # -------- 写 loc_comment.md（与 loc.md 一致）--------
    if args.comment_output:
        Path(args.comment_output).write_text(final_md, encoding="utf-8")
        print(f"[report] Generated {args.comment_output}")

    print("[report] Generated loc.json, loc.md")


if __name__ == "__main__":
    main()
