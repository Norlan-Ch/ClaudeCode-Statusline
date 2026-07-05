#!/usr/bin/env bash
# statusline 重构后的端到端验证：语法 + 各场景渲染 + 降级/空行/边界
S=/home/dralfo/.claude/statusline/statusline-command.sh
SCRATCH=$(mktemp -d)

strip() { sed $'s/\x1b\\[[0-9;]*m//g'; }   # 去掉 ANSI 颜色，只看结构

echo "=========== bash -n 语法检查 ==========="
if bash -n "$S"; then echo "OK: 语法通过"; else echo "FAIL: 语法错误"; exit 1; fi

# 准备一个真实 git 仓库（长分支名），用于第1行 path|branch 的两行布局测试
REPO="$SCRATCH/testrepo"
rm -rf "$REPO"
mkdir -p "$REPO/very/deeply/nested/project/dir"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/feature/a-very-long-branch-name-for-truncation-test

now=$(date +%s)
reset=$((now + 13500))   # +3h45m

# 所有用例都在非 git 的 SCRATCH 目录下运行，令 $PWD 可控（git 段仅由 current_dir 决定）
run() {
    local title="$1" json="$2"
    echo
    echo "=========== $title ==========="
    local out
    out=$( cd "$SCRATCH" && printf '%s' "$json" | bash "$S" )
    echo "--- 去色输出（结构） ---"
    printf '%s\n' "$out" | strip
    printf '%s\n' "--- 输出行数=$(printf '%s' "$out" | grep -c '^') 字节数=$(printf '%s' "$out" | wc -c) ---"
}

DEEP="$REPO/very/deeply/nested/project/dir"

run "T1 长路径+长分支+1M模型+ctx(1M窗口)+usage(有reset)" \
"{\"workspace\":{\"current_dir\":\"$DEEP\"},\"model\":{\"display_name\":\"Opus 4.8 (1M context)\"},\"effort\":{\"level\":\"max\"},\"context_window\":{\"total_input_tokens\":60009,\"context_window_size\":1000000,\"used_percentage\":6.0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":$reset}}}"

run "T2 home(~)+无git+普通模型名(不含1M)+ctx(200K)+usage(无reset)" \
"{\"workspace\":{\"current_dir\":\"$HOME\"},\"model\":{\"display_name\":\"Sonnet 4.6\"},\"effort\":{\"level\":\"medium\"},\"context_window\":{\"total_input_tokens\":120000,\"context_window_size\":200000,\"used_percentage\":60},\"rate_limits\":{\"five_hour\":{\"used_percentage\":55}}}"

run "T3 非git目录+仅model(无effort、无ctx、无usage)" \
"{\"workspace\":{\"current_dir\":\"$SCRATCH\"},\"model\":{\"display_name\":\"Haiku 4.5\"}}"

run "T4 全空 stdin（两行都应为空 → 无任何输出，字节数应为0）" \
"{}"

run "T7 第1行空(无path无git) + 第2行有model（应只输出1行，且不以空行开头）" \
"{\"model\":{\"display_name\":\"Opus 4.8 (1M context)\"},\"effort\":{\"level\":\"high\"}}"

# dirty 场景：在 repo 里造一个 untracked 文件，验证黄色 + 尾部 *
touch "$REPO/dirty_file.txt"
run "T8 dirty git（应为 分支名* ，本用例只看第1行 git 段）" \
"{\"workspace\":{\"current_dir\":\"$DEEP\"},\"model\":{\"display_name\":\"Sonnet 4.6\"}}"

echo
echo "=========== 原始带颜色输出抽查（T1，确认颜色真的生效） ==========="
( cd "$SCRATCH" && printf '%s' "{\"workspace\":{\"current_dir\":\"$DEEP\"},\"model\":{\"display_name\":\"Opus 4.8 (1M context)\"},\"effort\":{\"level\":\"max\"},\"context_window\":{\"total_input_tokens\":60009,\"context_window_size\":1000000,\"used_percentage\":6.0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":$reset}}}" | bash "$S" ) | cat -v

echo
echo "=========== 确认脚本不再含 curl / accessToken / 缓存 ==========="
grep -nE 'curl|accessToken|quota_cache_file|write_quota_cache|retry_after' "$S" && echo "FAIL: 仍残留兜底相关代码" || echo "OK: 已彻底移除兜底/网络/凭据读取"

rm -rf "$REPO"
