#!/usr/bin/env bash
# ==============================================================================
# 一次性安装脚本：在新机器 clone 本仓库后运行，注册 /statusline-mine 命令（建软链）。
#
# 为什么需要它、以及它「只」做这一件事：
#   - Claude Code 只在 ~/.claude/commands/ 下发现 user 级命令，而该软链不随 git 走，
#     故换机 / 全新 clone 后必须重建——这是 /statusline-mine 命令本身无法自举的一步
#     （软链没建好，命令就不存在、无从调用；先有鸡才有蛋）。
#   - 激活 statusline 本身（写 settings.json 的 statusLine / subagentStatusLine）是
#     /statusline-mine 命令的职责，本脚本「刻意不做」，以免与其重复实现、日后漂移。
#     软链建好后，在 Claude Code 内跑一次 /statusline-mine 即完成激活。
#
# 特性：路径自适应（clone 到任意目录都对、不硬编码）、尊重 CLAUDE_CONFIG_DIR、幂等、
#       改动前一律备份、绝不静默删除非本脚本创建的文件。
# 依赖：无（纯 coreutils；不需要 jq、无网络请求）。
# ==============================================================================
set -euo pipefail

# 仓库根 = 本脚本所在目录的绝对路径 —— 换机 / clone 到任意位置都自适应
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Claude Code 配置目录：尊重 CLAUDE_CONFIG_DIR，缺省 ~/.claude
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CMDDIR="$CLAUDE_DIR/commands"
CMD_SRC="$REPO_DIR/statusline-mine.md"
CMD_LINK="$CMDDIR/statusline-mine.md"

echo "仓库目录：$REPO_DIR"
echo "配置目录：$CLAUDE_DIR"
echo

[ -f "$CMD_SRC" ] || { echo "错误：仓库内缺少 $CMD_SRC，安装中止" >&2; exit 1; }

# mkdir -p 对已存在目录是幂等 no-op：不报错、不动其中任何文件与权限
mkdir -p "$CMDDIR"

if [ -L "$CMD_LINK" ] && [ "$(readlink "$CMD_LINK")" = "$CMD_SRC" ]; then
    echo "[跳过] 命令软链已正确指向仓库文件"
elif [ -e "$CMD_LINK" ] || [ -L "$CMD_LINK" ]; then
    # 已存在但不是本脚本的正确软链（普通文件 / 指向别处的旧链 / 断链）→ 备份后替换，绝不静默删除
    # 备份名附进程号，保证同秒内多次运行也不撞名
    bak="$CMD_LINK.bak.$(date +%Y%m%d%H%M%S)-$$"
    mv "$CMD_LINK" "$bak"
    ln -s "$CMD_SRC" "$CMD_LINK"
    echo "[替换] 原 $CMD_LINK 已备份为 $bak；重建软链 → $CMD_SRC"
else
    ln -s "$CMD_SRC" "$CMD_LINK"
    echo "[创建] 命令软链 $CMD_LINK → $CMD_SRC"
fi

echo
echo "✅ /statusline-mine 命令已注册。"
echo "   下一步：在 Claude Code 内运行一次 /statusline-mine，即把 statusLine / subagentStatusLine"
echo "   指向本仓库脚本、激活两行 statusline（热重载、无需重启）。"
