# Claude Code 自定义 Statusline 设计文档

> 最后更新：2026-07-06（第2行新增 Week 周窗口用量[绝对重置时刻]、第3行 RAM 三档变色 + 各段 emoji 前缀，均已端到端验证）

## 概述

三行 statusline，行内用亮灰色 ` | ` 分隔，不使用中括号：

```
第1行：路径 | Git分支
第2行：模型 (Effort) | Token用量 | 5h配额 | 周配额
第3行：🕐会话时长 | 💾内存 | ⏳缓存过期时刻 | 💰花费
```

分行原则：第1行「我在哪」（定位，变化慢），第2行「当前状态」（模型 + 高频变化的用量，三档变色），第3行「会话运行时」（累计/系统指标，多为中性色、仅 RAM 参与变色，不喧宾夺主）。单行时长路径会把右侧挤出终端截断，故拆行。

渲染样例：
```
~/workspace/mine | main
Opus 4.8 [1m] (Max) | 60K/1.0M (6%) | Max 25% (3h 45m / 5h) | Week 41% (3d 4h / Thu 05:27)
🕐 Up 1h 23m | 💾 RAM 21% (4.9G/23G) | ⏳ Cache 21:48 | 💰 $1.23
```

## 文件清单

所有 statusline 资产集中在 **`~/.claude/statusline/`**（自包含）；仅 `settings.json` 因是 Claude Code 全局配置而留在 `~/.claude/` 根。

| 文件 | 作用 |
|---|---|
| `~/.claude/statusline/statusline-command.sh` | 主脚本（Bash，依赖 `jq` / `git` / `date` / `grep` / `tail`，**无网络请求**；另读 `/proc/meminfo` 与 transcript 末尾若干行。`date` 尤关键：缓存绝对时刻、`to_epoch`、配额剩余全靠它） |
| `~/.claude/statusline/DESIGN.md` | 本设计文档 |
| `~/.claude/statusline/verify_statusline.sh`<br>`~/.claude/statusline/verify_line3.sh` | 端到端验证脚本（`SCRATCH=$(mktemp -d)` 自建临时目录、可复用） |
| `~/.claude/statusline/debug.json` | 运行时调试输出，每次覆盖写入（多会话共享；若目录纳入 git 应 gitignore） |
| `~/.claude/settings.json` | `statusLine.command = "bash /home/dralfo/.claude/statusline/statusline-command.sh"` |

## statusline 刷新机制（决定了缓存段的设计）

官方文档（code.claude.com/docs/en/statusline）明确：

- **事件驱动**：脚本在「新 assistant 消息 / `/compact` 完成 / permission mode 变更 / vim mode 切换」时才重跑，**不是**定时轮询。
- **300ms 防抖**：快速连续的更新合并为一次执行；脚本还在跑时被新触发会取消。
- **空闲时静止**：无对话活动则不自动重绘，停在上次输出。
- **stdin 每次都是最新快照**（cost / context_window / rate_limits 当场重采）。
- 可选 `refreshInterval: N`（秒，最小 1）叠加定时刷新——本设计**不使用**（见「缓存过期时刻」）。

## 通用规则

- **段内降级**：任一区域数据缺失 → 该区域（含前导分隔符）整段隐藏。
- **整行降级**：某一行所有区域都缺失 → 该行不输出（不留空行）；只有部分行有内容就只输出那些行。
- **三档变色**（Token 用量、Usage 配额[5h/周]、以及第3行 RAM）：<50% 绿 / 50–79% 黄 / ≥80% 红。第3行**其余段**（会话时长/缓存/花费）一律默认前景色，仅「缓存已过期」用亮灰；RAM 是第3行**唯一**参与变色的段。
- **颜色**（16 色 ANSI）：分隔符亮灰 `\e[90m`、路径青 `\e[36m`、模型品红 `\e[35m`、绿/黄/红；每色块后 `\e[0m`。
- **第3行 emoji 前缀**（2026-07-06，fable 5 选型）：`🕐 Up` / `💾 RAM` / `⏳ Cache` / `💰 $`。均 Unicode 6.0 emoji-presentation、**无需 VS16(U+FE0F)**、等宽终端宽度恒 2 列（刻意避开 ⏱/⏲ 这类需 VS16、宽度不定者，及 📅/🗓 会把 `HH:MM` 误读为日期者）。作**前缀保留文字标签**（`💾 42%` 单看不辨 RAM/CPU，标签不可省；仅花费段因 `$` 自带标签而无需加词）。段间分隔符仍统一 ` | `（不因 emoji 改双空格，保持三行分隔风格一致）。
- 渲染装入 `line1_segments` / `line2_segments` / `line3_segments` 三数组，各自拼接、`[ -n ]` 判空后 `printf`。

## 各区域规格

### 第1行 · 路径（青色）
数据源 `workspace.current_dir`（兜底 `.cwd`）；home 缩 `~`，不截断。

### 第1行 · Git 分支
非仓库整段隐藏；干净=绿分支名；dirty（含 untracked）=黄 + ` *N`（N=dirty 文件总数，`printf '%s\n' "$porcelain" | grep -c '^'`，**复用现有 `status --porcelain` 调用，零额外 git 调用**）；detached=7 位短 hash；零提交仓库=`symbolic-ref` 取未诞生分支名。**`*N` 仅在 dirty 时出现、与分支形态无关**——干净的分支名 / detached hash / unborn 分支名都不带数字。

**不显示 ahead/behind**（经权衡放弃）：`@{upstream}` 是每分支唯一的 tracking 配置（`branch.<名>.remote`+`.merge`），显示为 `<remote>/<branch>`，不硬编码 origin、多 remote 不混淆、无 tracking 则该命令失败——语义上完全可实现（`git rev-list --left-right --count @{upstream}...HEAD`，三点对称差同时给领先/落后，diverged 显示 `↑2 ↓1`），但用户主要单机、更看重「手头堆了多少改动」，故只保留工作区计数、省去一次 `rev-list`。

### 第2行 · 模型 (Effort)（品红色）
`model.display_name`；`${model_name/ (1M context)/ [1m]}` 把 1M 变体后缀简写为 `[1m]`（普通模型名无副作用）；effort 映射 `low→Low/medium→Med/high→High/xhigh→XHigh/max→Max`，取不到不留空括号。例 `Opus 4.8 [1m] (Max)`。

### 第2行 · Token 用量（三档变色）
`5K/200K (2%)`。主路径 stdin `context_window.*`（百分比**优先复用 stdin 的 `used_percentage`**，仅其缺失时才 `t/s*100` 自算）；回退解析 transcript 最后一条 usage（`input+cache_creation+cache_read`，窗口硬编码 200000）。`format_k`：≥999,500→`X.XM`（M 档门槛 999,500 是为 K 档进位，`999,999→1.0M`）、≥1,000→`XK`、<1,000 原值。

### 第2行 · Usage 配额（5h + 周，三档变色）
**5h 窗口** `Max 55% (2h 10m / 5h)`。计划名读 `.credentials.json` 的 `subscriptionType`（不读 `accessToken`）。主路径 stdin `rate_limits.five_hour.*`，零网络零缓存。**计划名与 5h 数据缺一即整段隐藏**——`plan_name` 为空（无 `.credentials.json` 或 `subscriptionType` 缺失）时，即便 stdin 有 `rate_limits` 也不显示。剩余不足 1 小时省略小时位。

**周窗口（Week，2026-07-06 新增）** `Week 41% (3d 4h / Thu 05:27)`。同源 stdin `rate_limits.seven_day.*`（字段与 5h 完全一致：`used_percentage` / `resets_at`，`to_epoch` 兼容 epoch 与 ISO；权威 schema 经 claude-code-guide 确认无 opus 专属窗口）。标签固定 `Week`（不复用计划名，避免与 5h 段 `Max` 重复）。gate 与 5h 对称（需 `plan_name` + 自身数据）但**独立于 five_hour**：`rate_limits` 只含 seven_day 时 Week 照常显示、5h 段隐藏。剩余时间三分支：≥1 天 `Nd Nh`、≥1 小时 `Nh Nm`、否则 `Nm`。**重置显示为绝对时刻**「星期缩写 + 24h」`Thu 05:27`（`LC_ALL=C date '+%a %H:%M'` 强制英文星期）——而非 `/ 7d` 固定文案，理由同缓存段：绝对时刻不依赖 now、空闲不失真，星期缩写为最长 7 天跨度消歧。`rate_limits` 仅 Pro/Max 且首个 API 响应后出现，故 `// empty` 兜底。

### 第3行 · 会话时长（🕐 Up，默认色）
数据源 stdin `cost.total_duration_ms`（会话累计 wall-clock 毫秒）。格式（分钟粒度）：`<1m` / `45m` / `1h 23m`。`cost` 对象缺失（旧版 CLI）→ 隐藏。

### 第3行 · 内存（💾 RAM，三档变色）
系统整体内存：读 `/proc/meminfo` 的 `MemTotal`/`MemAvailable`（kB）。`used% = round((T-A)/T*100)`；绝对值 GiB，`fmt_gib`：≥10G 取整（`23G`）、<10G 一位小数（`4.9G`）。展示 `💾 RAM 21% (4.9G/23G)`。`/proc/meminfo` 读不到 → 隐藏。**2026-07-06 起套三档变色**（复用 `color_for_pct`，<50 绿 / 50–79 黄 / ≥80 红），是第3行唯一参与变色的段；本机 RAM 基线约 22–27%（24 GiB WSL2），平时绿、负载上来才黄/红。

### 第3行 · 缓存过期时刻（⏳ Cache，默认色 / 过期灰）

显示 prompt cache 将被丢弃的**本地绝对时刻**（`Cache 21:48`），而非相对倒计时。

**为什么用绝对时刻**：相对倒计时是 time-based 数据，随真实时间衰减，空闲时若不 `refreshInterval` 定时刷新就会「过时乐观」误导（屏幕卡在 58m，实际已快过期）；绝对时刻只依赖 `起算点 + TTL`（都固定、不依赖 now），**一次算出永不过时、无需定时刷新、零空闲开销**，且空闲静止时仍可自行判读（瞥一眼当前几点即知是否已过）。与「事件驱动、不折腾空闲机器」的整体哲学一致。

**动态 TTL（关键）**：Claude 的 prompt cache TTL 有两种——5 分钟（API 默认，`ephemeral`）与 1 小时（`ttl: "1h"`），**没有 0.5h**。Claude Code 实际用哪种由它自己决定；**本机实测全程用 1h**（可能与 Max 计划相关）。故不硬编码、不按计划猜，而是**从 transcript 的 `usage.cache_creation` 拆分动态读真实 TTL**：`ephemeral_1h_input_tokens>0 → 3600s`，否则 `ephemeral_5m_input_tokens>0 → 300s`。无论 CLI 未来用哪种都自动正确。

**算法**：tail transcript 末尾 ~50 行 → 起算点 = 最后一条 `type=="assistant"` **且带 `usage`** 的 `timestamp`（ISO8601，`to_epoch` 转换）；TTL = 倒序最近一条 `cache_creation` 非零记录的档位；`expires_at = 起算点 + TTL`。渲染：`expires_at > now → Cache HH:MM`（`date -d @epoch +%H:%M` 本地时区，默认色）；`≤ now → Cache expired`（亮灰）；transcript/assistant/cache_creation 任一缺失 → 隐藏。无 warning 中间态（「快过期」本身 time-based，与「不刷新」冲突）。

### 第3行 · 花费（💰 $，默认色）
数据源 stdin `cost.total_cost_usd`（会话累计美元）。`cost_fmt`（jq 判小数位 + printf 补零）：≥1→2 位（`$1.23`）、≥0.1→3 位（`$0.123`）、>0→4 位（`$0.0042`）、`≤0`→`$0.00`（会话累计花费不会为负，负数也归 2 位）。缺失/非数字 → 隐藏。你是 Pro/Max 直连，无 Bedrock/Vertex 顾虑。

## 调试文件

`~/.claude/statusline/debug.json`，每次覆盖写入，字段：

`ts` / `quota_source`（`stdin_rate_limits` / `hidden`）/ `ctx_tokens` / `has_cost`（stdin 是否含 cost 对象）/ `cache_ttl`（检测到的 300/3600/null）/ `rendered_segments`（path/git/model/token/quota/week/up/ram/cache/cost）

**绝不包含 accessToken 或任何凭据。** 多会话共享同一文件会互相覆盖。

## 验收记录

**2026-07-06 Week 周用量 + RAM 变色 + 第3行 emoji**，主会话 Bash 端到端实测通过（构造多组 stdin/transcript）：
- 全量：第2行尾部 `Week 41% (3d 4h / Thu 05:27)`（绿）；第3行 `🕐 Up 1h 23m | 💾 RAM 27% (6.2G/23G)`（绿）`| 💰 $0.42`。
- Week 重置绝对时刻三分支：天 `3d 4h / Thu 05:27`、小时 `5h 0m / Mon 06:27`、分钟 `10m / Mon 01:37`；星期强制英文（`LC_ALL=C`）。颜色随 % 三档（41→绿 / 72→黄）。
- RAM 三档：`color_for_pct` 22→绿 / 60→黄 / 85→红；真实 ~27% 渲染为绿并正确前置 `\e[32m`。
- 缓存已过期 → `⏳ Cache expired`（灰）；emoji 前缀两分支均在。
- 降级：无 `rate_limits` → 5h 与 Week 一并隐藏（第2行只剩模型+token）；仅 `seven_day` → Week 显示、5h 隐藏（独立 gating）。
- emoji 均真实 UTF-8 字节、`bash -n` 通过。

**2026-07-05 三行重构**，主会话 Bash 端到端实测通过（`verify_line3.sh`）：
- 完整三行：`Up 1h 23m | RAM 21% (4.9G/23G) | Cache 21:48 | $1.23`。
- 缓存动态 TTL：1h 档过期时刻 = 起算+60m、5m 档 = 起算+5m（两者精确差 55m）；`cache_ttl` 调试字段正确检测 3600/300。
- 缓存已过期 → `Cache expired`（灰）。
- cost 四档 `$1.23`/`$0.123`/`$0.0042`/`$0.00`；时长三档 `<1m`/`45m`/`1h 23m`。
- 降级：无 `cost` 对象 → Up+花费隐藏（`has_cost:false`）；无 transcript → Cache 隐藏。
- 颜色：第三行默认色，仅 `Cache expired` 灰。
- 前两行回归正常。单次刷新约 **71ms**（WSL2；较两行版 ~39ms 增加，来自 tail transcript + `/proc/meminfo` + 更多 jq，仍远低于 300ms 防抖上限）。

**Git 工作区计数（2026-07-05 后续）** 实测通过（`verify` inline）：干净→绿分支名无数字；1 改+2 未跟踪→`main *3`（黄）；detached+dirty→`0f67768 *3`；unborn+1 未跟踪→`main *1`；真实多 remote worktree（cycle2image）→`main *42`；颜色 `分支 *N` 整段黄。不含 ahead/behind。

**历史验收（逻辑未变仍有效）**：format_k 进位边界八组；两行布局降级/空行；Git 各态；移除 OAuth API 兜底。

## 已知限制

- Token 回退路径 200K 硬编码窗口对 1M 模型高估百分比。
- 1M 简写依赖 `display_name` 精确为 `... (1M context)`；文案变则简写失效（回落原样，不报错）。
- 缓存段依赖 transcript 记录 `usage.cache_creation` 的 5m/1h 拆分字段；若 CLI 未来改字段名则该段隐藏（降级）。绝对时刻需读者知当前时钟（B 方案唯一代价）。
- 内存为 WSL2 视角（WSL 虚机内存，非 Windows 全量）——预期行为。

## 与 claude-hud 切换对比

Claude Code 的 **plugin 机制不能声明主 `statusLine`**（官方 plugins-reference：plugin 的 settings.json 只支持 `agent` / `subagentStatusLine`）。所以 claude-hud（`jarrodwatts/claude-hud`）不是「叠加一个 statusLine」，而是靠 `/claude-hud:setup` 命令**改写 `~/.claude/settings.json` 里那唯一的 `statusLine.command`**——本质是覆盖同一字段，谁最后写谁生效，不存在优先级/冲突问题。

**方向对应（两个方向各管各的，无 dispatcher）：切到 hud = `/claude-hud:setup`，切回本脚本 = `/statusline-mine`。**

**切法一 · 用 slash 命令改 settings.json（最直白，statusLine 热重载、无需重启即时生效）**

> **生效时机（已实测核实，2026-07）**：Claude Code 用 file watcher 监听 `settings.json`，改动会**热重载**进内存（并触发 `ConfigChange` hook）；statusLine 又是事件驱动重渲染（新 assistant 消息 / `/compact` / permission mode 变更 / vim mode 切换）。所以改完 `.statusLine.command` **无需重启**，等下一次刷新事件即生效——发一条消息就能触发。官方 settings 文档只显式把 `model` / `outputStyle` 归为「启动期读取、需重启」，statusLine 不在其列（文档对 statusLine 沉默，结论以实测为准）。**重启只是「万一 watcher 没触发刷新」的兜底**，不是前提。

- 切到 claude-hud：`/claude-hud:setup`（选 “Replace it with claude-hud”）。首次需先 `/plugin marketplace add jarrodwatts/claude-hud` → `/plugin install claude-hud`（WSL 建议 `mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude` 规避 EXDEV）。setup 会自动备份 `settings.json.bak.<时间戳>`，并把旧命令原文存到 `~/.claude/plugins/claude-hud/previous-statusline.txt`。
- 切回本脚本：`/statusline-mine`（user 级自定义命令，文件 `~/.claude/commands/statusline-mine.md`；扁平命名、非 plugin）。它用 `jq` 只把 `.statusLine.command` 改回 `bash /home/dralfo/.claude/statusline/statusline-command.sh`（`.statusLine` 整段缺失时顺带用 `//=` 补回 `type`），先写临时文件再原子 `mv`，其余所有设置一个不动。`/statusline-mine` 只负责「切回我的脚本」这一个方向，不试图捕获/复现 hud 命令。兜底手段仍可用：`cp $(ls -t ~/.claude/settings.json.bak.* | head -1) ~/.claude/settings.json`，或从 `previous-statusline.txt` 读回旧命令。

**切法二 · wrapper 分发（频繁 A/B 首选，零改配置、每会话切换）**
把 `statusLine.command` 一次性指向一个分发脚本，按环境变量选择（两者读同一份 stdin，`exec` 继承 stdin）：
```bash
# ~/.claude/statusline-switch.sh
if [ "${USE_HUD:-0}" = "1" ]; then
    exec <此处填 claude-hud setup 生成的启动命令，装好后从 settings.json 里拷那段 bash -c '...dist/index.js...'>
else
    exec bash /home/dralfo/.claude/statusline-command.sh
fi
```
之后 `USE_HUD=1 claude` = claude-hud，`claude` = 本脚本，互不改文件。

**注意**：`CLAUDE_HUD_DISABLE=1 claude` 只在「claude-hud / 空白」间切，**不会回退到本脚本**，不能用于二者 A/B；且若在 shell profile 里 export 了它会全局静默 claude-hud。切法一改 `statusLine.command` **无需重启**、下一次刷新事件即热生效（见上；重启仅作兜底）；切法二靠启动期 `USE_HUD` 选分支，切换本就要开新会话。

## 维护方式

后续修改统一通过 **statusline-setup agent**（无 Bash 权限，语法与行为验证由主会话用 Bash 完成：`bash -n` + 构造 stdin/transcript 端到端跑，复用 `~/.claude/statusline/` 下的 `verify_statusline.sh` / `verify_line3.sh`）。
