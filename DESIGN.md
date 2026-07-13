# Claude Code 自定义 Statusline 设计文档

> 最后更新：2026-07-13（新增 **subagent 面板行**渲染脚本 `subagent-statusline.sh`：状态点·名称·模型·上下文占用·运行时长，模型按档位/系列上色[Claude opus 紫/sonnet 黄/haiku 绿/fable 七彩、GPT luna→terra→sol 蓝到青]，模型名美化仅作用于 Claude 系列）
> 历史更新：2026-07-06（配色收敛：path 橙[256 色]/干净分支亮蓝；Usage 改 5h/7d 标签[去订阅档位、去凭据读取]；第3行仅 emoji、无文字标签；均已端到端验证）

本设计包含两个相互独立的渲染脚本，各由 `settings.json` 的不同字段驱动：

- **主 statusline**（`statusline-command.sh`）：底部三行状态栏，由 `statusLine.command` 驱动 —— 见「[主 statusline](#主-statusline)」。
- **subagent 面板行**（`subagent-statusline.sh`）：subagent 面板中每个正在运行的 Task 一行，由 `subagentStatusLine.command` 驱动 —— 见「[Subagent 面板行](#subagent-面板行)」。

## 文件清单

所有 statusline 资产集中在 **`~/.claude/statusline/`**（自包含、纳入 git）；仅 `settings.json` 因是 Claude Code 全局配置而留在 `~/.claude/` 根。slash 命令 `statusline-mine.md` 的**真实文件也在本仓库**，靠 `~/.claude/commands/` 下的符号链接被 Claude Code 发现（见下）。

| 文件 | 作用 |
|---|---|
| `~/.claude/statusline/statusline-command.sh` | 主 statusline 脚本（Bash，依赖 `jq` / `git` / `date` / `grep` / `tail`，**无网络请求**；另读 `/proc/meminfo` 与 transcript 末尾若干行。`date` 尤关键：缓存绝对时刻、`to_epoch`、配额剩余全靠它） |
| `~/.claude/statusline/subagent-statusline.sh` | subagent 面板行脚本（Bash，依赖 `jq` / GNU `date`[`%s%3N` 取毫秒]，**无网络请求**；仅消费 stdin 的 `.tasks[]`，无文件读取） |
| `~/.claude/statusline/statusline-mine.md` | `/statusline-mine` slash 命令的**真实文件**（纳入本仓库版本管理）；把 `.statusLine.command` 与 `.subagentStatusLine.command` 一并切回本仓库脚本。详见 [与 claude-hud 切换对比](#与-claude-hud-切换对比) |
| `~/.claude/commands/statusline-mine.md` | **符号链接** → `~/.claude/statusline/statusline-mine.md`。Claude Code 只在 `~/.claude/commands/` 下发现 user 级命令，故在此建软链；软链每次访问都**解析到仓库内真实文件**，因此编辑仓库文件即实时生效、无需拷贝（软链是独立 inode，非 hardlink）。链接本身在仓库外、不被任何 git 跟踪 |
| `~/.claude/statusline/DESIGN.md` | 本设计文档 |
| `~/.claude/statusline/verify_statusline.sh`<br>`~/.claude/statusline/verify_line3.sh` | 端到端验证脚本（`SCRATCH=$(mktemp -d)` 自建临时目录、可复用） |
| `~/.claude/statusline/debug.json` | 主 statusline 的运行时调试输出，每次覆盖写入（多会话共享；若目录纳入 git 应 gitignore）。subagent 脚本无调试文件 |
| `~/.claude/settings.json` | `statusLine.command = "bash /home/dralfo/.claude/statusline/statusline-command.sh"`<br>`subagentStatusLine.command = "bash /home/dralfo/.claude/statusline/subagent-statusline.sh"` |

## 主 statusline

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
Opus 4.8 (Max) | 60K/1.0M (6%) | 5h 2% (3h 50min) | 7d 5% (2d 7h, Wed 19:00)
🕐 1h 23m | 💾 21% (4.9G/23G) | ⏳ 21:48 | 💰 $1.23
```

### 刷新机制（决定了缓存段的设计）

官方文档（code.claude.com/docs/en/statusline）明确：

- **事件驱动**：脚本在「新 assistant 消息 / `/compact` 完成 / permission mode 变更 / vim mode 切换」时才重跑，**不是**定时轮询。
- **300ms 防抖**：快速连续的更新合并为一次执行；脚本还在跑时被新触发会取消。
- **空闲时静止**：无对话活动则不自动重绘，停在上次输出。
- **stdin 每次都是最新快照**（cost / context_window / rate_limits 当场重采）。
- 可选 `refreshInterval: N`（秒，最小 1）叠加定时刷新——本设计**不使用**（见「缓存过期时刻」）。

### 通用规则

- **段内降级**：任一区域数据缺失 → 该区域（含前导分隔符）整段隐藏。
- **整行降级**：某一行所有区域都缺失 → 该行不输出（不留空行）；只有部分行有内容就只输出那些行。
- **三档变色**（Token 用量、Usage 配额[5h/7d]、以及第3行 RAM）：<50% 绿 / 50–79% 黄 / ≥80% 红。第3行**其余段**（会话时长/缓存/花费）一律默认前景色，仅「缓存已过期」用亮灰；RAM 是第3行**唯一**参与变色的段。
- **颜色**（多为 16 色 ANSI，路径用 256 色）：分隔符亮灰 `\e[90m`、路径橙 `\e[38;5;208m`（256 色）、模型品红 `\e[35m`、Git 干净分支亮蓝 `\e[94m`、用量绿/黄/红；每色块后 `\e[0m`。
- **第3行 emoji（仅 emoji、无文字标签）**（2026-07-06；emoji 由 fable 5 选型）：`🕐 <时长>` / `💾 <RAM%>` / `⏳ <时刻/expired>` / `💰 <$>`。均 Unicode 6.0 emoji-presentation、**无需 VS16(U+FE0F)**、等宽终端宽度恒 2 列（刻意避开 ⏱/⏲ 这类需 VS16、宽度不定者，及 📅/🗓 会把 `HH:MM` 误读为日期者）。**2026-07-06 起移除 Up/RAM/Cache 文字标签**，仅留 emoji 承载类别（🕐时长 / 💾内存 / ⏳缓存 / 💰花费；花费段 `$` 亦自带含义）。段间分隔符仍统一 ` | `（不因 emoji 改双空格，保持三行分隔风格一致）。
- 渲染装入 `line1_segments` / `line2_segments` / `line3_segments` 三数组，各自拼接、`[ -n ]` 判空后 `printf`。

### 各区域规格

#### 第1行 · 路径（橙色）
数据源 `workspace.current_dir`（兜底 `.cwd`）；home 缩 `~`，不截断。

#### 第1行 · Git 分支
非仓库整段隐藏；干净=**亮蓝**分支名（`\e[94m`，刻意避开用量低档的绿以免撞色）；dirty（含 untracked）=黄 + ` *N`（N=dirty 文件总数，`printf '%s\n' "$porcelain" | grep -c '^'`，**复用现有 `status --porcelain` 调用，零额外 git 调用**）；detached=7 位短 hash；零提交仓库=`symbolic-ref` 取未诞生分支名。**`*N` 仅在 dirty 时出现、与分支形态无关**——干净的分支名 / detached hash / unborn 分支名都不带数字。

**不显示 ahead/behind**（经权衡放弃）：`@{upstream}` 是每分支唯一的 tracking 配置（`branch.<名>.remote`+`.merge`），显示为 `<remote>/<branch>`，不硬编码 origin、多 remote 不混淆、无 tracking 则该命令失败——语义上完全可实现（`git rev-list --left-right --count @{upstream}...HEAD`，三点对称差同时给领先/落后，diverged 显示 `↑2 ↓1`），但用户主要单机、更看重「手头堆了多少改动」，故只保留工作区计数、省去一次 `rev-list`。

#### 第2行 · 模型 (Effort)（品红色）
`model.display_name`；`${model_name/ (1M context)/}` 把 1M 变体后缀 ` (1M context)` **整段剥除**（token 段的 `1.0M` 窗口已表明 1M 上下文，无需在模型名重复标记；普通模型名无副作用）；effort 映射 `low→Low/medium→Med/high→High/xhigh→XHigh/max→Max`，取不到不留空括号。例 `Opus 4.8 (Max)`。

#### 第2行 · Token 用量（三档变色）
`5K/200K (2%)`。主路径 stdin `context_window.*`（百分比**优先复用 stdin 的 `used_percentage`**，仅其缺失时才 `t/s*100` 自算）；回退解析 transcript 最后一条 usage（`input+cache_creation+cache_read`，窗口硬编码 200000）。`format_k`：≥999,500→`X.XM`（M 档门槛 999,500 是为 K 档进位，`999,999→1.0M`）、≥1,000→`XK`、<1,000 原值。

#### 第2行 · Usage 配额（5h + 7d，标签即窗口大小，三档变色）
**2026-07-06 重构**：标签由订阅档位（`Max`）改为**窗口大小**（`5h` / `7d`），并**彻底移除 `.credentials.json` 读取**（原只为取档位名，现无用）；两窗口各自仅凭自身 `rate_limits` 数据 gate（零网络、零缓存、零凭据）。

**5h 窗口** `5h 2% (3h 50min)`。数据源 stdin `rate_limits.five_hour.*`；gate：仅 `five_pct_raw` 存在即显示。剩余时间：≥1 小时 `Xh Ymin`、否则 `Ymin`（**不显示绝对时刻**——5h 窗口短、相对剩余已够）。

**7d 窗口** `7d 5% (2d 7h, Wed 19:00)`。同源 stdin `rate_limits.seven_day.*`（字段与 5h 一致：`used_percentage` / `resets_at`，`to_epoch` 兼容 epoch 与 ISO；权威 schema 经 claude-code-guide 确认无 opus 专属窗口）。gate 独立于 five_hour（各自数据）：只含 seven_day 时 7d 照常显示、5h 隐藏。剩余时间三分支：≥1 天 `Xd Yh`、≥1 小时 `Xh Ymin`、否则 `Ymin`；后接 `, ` 再跟**绝对重置时刻**「星期缩写 + 24h」`Wed 19:00`（`LC_ALL=C date '+%a %H:%M'` 强制英文星期）——绝对时刻不依赖 now、空闲不失真，星期缩写为最长 7 天跨度消歧。`rate_limits` 仅 Pro/Max 且首个 API 响应后出现，故 `// empty` 兜底。

#### 第3行 · 会话时长（🕐，默认色）
数据源 stdin `cost.total_duration_ms`（**进程级**累计 wall-clock 毫秒——随 `claude` 进程生命周期计，`/clear`、`/resume` 均不重置，仅退出重启进程才归零；详见 `INVESTIGATION-cost-duration-reset.md`）。显示 `🕐 <时长>`（2026-07-06 起去 "Up" 文字）；格式（分钟粒度）：`<1m` / `45m` / `1h 23m`。`cost` 对象缺失（旧版 CLI）→ 隐藏。

#### 第3行 · 内存（💾，三档变色）
系统整体内存：读 `/proc/meminfo` 的 `MemTotal`/`MemAvailable`（kB）。`used% = round((T-A)/T*100)`；绝对值 GiB，`fmt_gib`：≥10G 取整（`23G`）、<10G 一位小数（`4.9G`）。展示 `💾 21% (4.9G/23G)`（2026-07-06 起去 "RAM" 文字）。`/proc/meminfo` 读不到 → 隐藏。**2026-07-06 起套三档变色**（复用 `color_for_pct`，<50 绿 / 50–79 黄 / ≥80 红），是第3行唯一参与变色的段；本机 RAM 基线约 22–27%（24 GiB WSL2），平时绿、负载上来才黄/红。

#### 第3行 · 缓存过期时刻（⏳，默认色 / 过期灰）

显示 prompt cache 将被丢弃的**本地绝对时刻**（`⏳ 21:48`，2026-07-06 起去 "Cache" 文字），而非相对倒计时。

**为什么用绝对时刻**：相对倒计时是 time-based 数据，随真实时间衰减，空闲时若不 `refreshInterval` 定时刷新就会「过时乐观」误导（屏幕卡在 58m，实际已快过期）；绝对时刻只依赖 `起算点 + TTL`（都固定、不依赖 now），**一次算出永不过时、无需定时刷新、零空闲开销**，且空闲静止时仍可自行判读（瞥一眼当前几点即知是否已过）。与「事件驱动、不折腾空闲机器」的整体哲学一致。

**动态 TTL（关键）**：Claude 的 prompt cache TTL 有两种——5 分钟（API 默认，`ephemeral`）与 1 小时（`ttl: "1h"`），**没有 0.5h**。Claude Code 实际用哪种由它自己决定；**本机实测全程用 1h**（可能与 Max 计划相关）。故不硬编码、不按计划猜，而是**从 transcript 的 `usage.cache_creation` 拆分动态读真实 TTL**：`ephemeral_1h_input_tokens>0 → 3600s`，否则 `ephemeral_5m_input_tokens>0 → 300s`。无论 CLI 未来用哪种都自动正确。

**算法**：tail transcript 末尾 ~50 行 → 起算点 = 最后一条 `type=="assistant"` **且带 `usage`** 的 `timestamp`（ISO8601，`to_epoch` 转换）；TTL = 倒序最近一条 `cache_creation` 非零记录的档位；`expires_at = 起算点 + TTL`。渲染：`expires_at > now → ⏳ HH:MM`（`date -d @epoch +%H:%M` 本地时区，默认色）；`≤ now → ⏳ expired`（亮灰）；transcript/assistant/cache_creation 任一缺失 → 隐藏。无 warning 中间态（「快过期」本身 time-based，与「不刷新」冲突）。

#### 第3行 · 花费（💰 $，默认色）
数据源 stdin `cost.total_cost_usd`（**进程级**累计美元——随 `claude` 进程生命周期计，`/clear`、`/resume` 均不重置；详见 `INVESTIGATION-cost-duration-reset.md`）。`cost_fmt`（jq 判小数位 + printf 补零）：≥1→2 位（`$1.23`）、≥0.1→3 位（`$0.123`）、>0→4 位（`$0.0042`）、`≤0`→`$0.00`（进程累计花费不会为负，负数也归 2 位）。缺失/非数字 → 隐藏。你是 Pro/Max 直连，无 Bedrock/Vertex 顾虑。

> **注**：曾于 2026-07-08 实现过「按 `session_id` 存基线、`/clear` 后归零」的方案，2026-07-09 回退。原因：`/resume` 复用同一 `session_id` 但走新进程、`raw` 从 0 起（实测坐实），基线机制解决不了 resume，反徒增 `state/` 文件与清理复杂度。完整调查见 `INVESTIGATION-cost-duration-reset.md`。

### 调试文件

`~/.claude/statusline/debug.json`，每次覆盖写入，字段：

`ts` / `quota_source`（`stdin_rate_limits` / `hidden`）/ `ctx_tokens` / `has_cost`（stdin 是否含 cost 对象）/ `cache_ttl`（检测到的 300/3600/null）/ `rendered_segments`（path/git/model/token/quota/week/up/ram/cache/cost）

**绝不包含 accessToken 或任何凭据。** 多会话共享同一文件会互相覆盖。

### 验收记录

**2026-07-06 配色收敛 + Usage 标签化 + 第3行去文字**，主会话 Bash 端到端实测通过：
- 配色：path 橙 `\e[38;5;208m`（256 色，与分支亮蓝/黄及全部现用色区隔）；干净分支亮蓝、脏分支黄 `*N`。
- Usage：`5h 2% (3h 50min)` / `7d 5% (2d 7h, Wed 19:00)`——去订阅档位、标签改窗口大小、**彻底移除 `.credentials.json` 读取**；5h 只显剩余、7d 剩余 + `, ` + 绝对重置时刻（星期强制英文）。剩余三分支 `Xd Yh` / `Xh Ymin` / `Ymin` 均验。
- 第3行仅 emoji（去 Up/RAM/Cache 文字）：`🕐 1h 23m | 💾 28% (…) | ⏳ 18:30 | 💰 $0.42`；过期 `⏳ expired`（灰）。
- 降级：无 `rate_limits` → 5h/7d 一并隐藏；仅 `seven_day` → 7d 显示、5h 隐藏。`bash -n` 通过。

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

### 已知限制

- Token 回退路径 200K 硬编码窗口对 1M 模型高估百分比。
- 1M 后缀剥离依赖 `display_name` 精确为 `... (1M context)`；文案变则不剥离（回落原样，不报错）。
- 缓存段依赖 transcript 记录 `usage.cache_creation` 的 5m/1h 拆分字段；若 CLI 未来改字段名则该段隐藏（降级）。绝对时刻需读者知当前时钟（B 方案唯一代价）。
- 内存为 WSL2 视角（WSL 虚机内存，非 Windows 全量）——预期行为。

### 维护方式

后续修改统一通过 **statusline-setup agent**（无 Bash 权限，语法与行为验证由主会话用 Bash 完成：`bash -n` + 构造 stdin/transcript 端到端跑，复用 `~/.claude/statusline/` 下的 `verify_statusline.sh` / `verify_line3.sh`）。subagent 面板行的验证见其[维护与验证](#维护与验证)小节。

## Subagent 面板行

> 脚本：`subagent-statusline.sh`；由 `settings.json` 的 `subagentStatusLine.command` 驱动。与主 statusline **完全独立**（不同 stdin schema、不同输出协议、不共享代码）。

Claude Code 在 subagent 面板中为每个 Task 渲染一行。本脚本读 stdin 的 `.tasks[]` 数组，**逐 task** 输出一行自定义内容，覆盖系统默认渲染。

### 布局（方案 C·精简）

单行，段间用亮灰色 ` · ` 分隔（区别于主 statusline 的 ` | `）：

```
状态点 · 名称 · 模型 · 上下文占用 · 运行时长
```

渲染样例（ANSI 上色后示意）：
```
● research-agent · opus 4.8 · 36K/200K (18%) · 2m 18s
● gpt-worker · gpt-5.6-luna · 12K/272K (4%) · 42s
○ pending-task · haiku 4.5
```

### 输出协议

每行一个 JSON：`{"id": <task id>, "content": <渲染字符串>}`。

- **省略某 id** → 该 task 保留系统默认渲染。
- **`content` 给空串** → 隐藏该行。
- ESC 转义序列由 `jq --arg` 负责安全转义进 JSON 字符串。

逐 task 循环中，`.id` 缺失则 `continue` 跳过（无 id 无从回填）。

### 数据源（stdin `.tasks[]` 各字段）

| 字段 | 用途 | 版本 |
|---|---|---|
| `.id` | 输出协议的回填键（缺失即跳过该 task） | — |
| `.name`（回退 `.label`→`.description`→`.type`→`"agent"`） | 名称段 | — |
| `.status` | 状态点颜色/形状 | — |
| `.model` | 模型段（档位/系列上色 + 美化） | v2.1.205+，可能缺省 |
| `.contextWindowSize` | 上下文占用段的窗口分母 | v2.1.205+，可能缺省 |
| `.tokenCount` | 上下文占用段的分子 | — |
| `.startTime`（毫秒） | 运行时长段（与当前毫秒时刻求差） | — |

### 状态点（`dot`）

`.status` → 彩色圆点：`running`/`active`/`in_progress` → 绿实心 `●`；`completed`/`done`/`success` → 亮灰实心 `●`；`failed`/`error`/`cancelled` → 红实心 `●`；其它/缺省 → 亮灰空心 `○`。

### 名称段

直接取 `.name`（多级回退见上表），不上色。

### 模型段（档位/系列上色 + 美化；缺省整段隐藏）

**颜色即成本信号**——按模型 ID 匹配档位色（`tier_color`）：

- Claude 系列：`opus` 紫（`38;5;135`，最贵）/ `sonnet` 黄 / `haiku` 绿（便宜快）。
- **fable**：逐字符七彩循环（`rainbow_text`，赤橙黄绿青蓝紫 `RAINBOW=(196 208 226 46 51 27 129)`），最醒目。
- **GPT 系列**（经 cliproxyapi 接入）：`luna` 蓝（`38;5;27`）→ `terra` 天蓝（`38;5;39`）→ `sol` 青（`38;5;51`），由蓝到青均匀渐变。
- 未知模型兜底品红。

**模型名美化（`pretty`，仅作用于 Claude 系列）**（2026-07-13 定稿，见 commit `ebf9ecf`/`a4c21a4`/`b9d8503`）：

- **非 `claude-` 前缀**（如 GPT 的 `gpt-5.6-luna`）→ **原样返回**，保持官方 ID 形态（否则会破坏 `gpt-5.6` 这类原生命名）。
- **`claude-` 前缀**：去 `claude-` 前缀 → 去 `[1m]` 等方括号变体后缀（窗口大小已由 `contextWindowSize` 读数体现，无需重复标记）→ 去尾部 `-YYYYMMDD` 日期 → 走**通用版本号规则**：按 `-` 分段，相邻「数字段」用 `.` 连接、其余分段用空格分隔。例：`claude-opus-4-8[1m]` → `opus 4.8`；`claude-haiku-4-5-20251001` → `haiku 4.5`；`claude-sonnet-5` → `sonnet 5`。**不针对具体模型名特判**，纯规则驱动。

`model_render`：`fable` 走 `rainbow_text`，其余走 `tier_color` 单色。

### 上下文占用段（三档变色；窗口未知则退化）

`tokenCount/contextWindowSize (占用%)`，如 `36K/200K (18%)`。占用率三档变色（复用 `color_pct`：<50 绿 / 50–79 黄 / ≥80 红，与主 statusline 同调色）。

- `contextWindowSize` 与 `tokenCount` 齐备（且窗口非 0）→ 完整 `token/window (pct%)`。
- **窗口未知**（v2.1.205 前或未解析）但有 `tokenCount` → 退化为纯 token 数（`fmt_tok`）。
- `fmt_tok`：`0` 原样、`≥1000` → `K`、`≥1000000` → `X.XM`。

### 运行时长段（`startTime` 毫秒实时计算）

`now_ms - startTime` 毫秒差（负数归 0），`fmt_dur` 人类可读：`42s` / `2m 18s` / `1h 05m`。当前毫秒由 `date +%s%3N`（GNU date）取得；`startTime` 缺失或 `now_ms` 非法则整段隐藏。

> **注**：面板行**没有主动定时刷新**——运行时长在下一次面板重绘事件时才更新。这与主 statusline 缓存段「一次算出、不依赖定时刷新」哲学一致；短命 task 通常随状态变更频繁重绘，够用。

### 段内降级

模型/上下文占用/运行时长各段**数据缺失即整段隐藏**（含前导 ` · `），只保留能渲染的段；状态点 + 名称是保底最小行。

### 维护与验证

改后 `bash -n` 校验，并构造带 `.tasks[]` 的 stdin（覆盖 Claude/GPT/fable 各系列、有无 `model`/`contextWindowSize`/`startTime` 的降级组合）逐行核对输出的 `{id, content}` JSON。语法与行为验证同样由主会话用 Bash 完成（subagent 脚本无专属 verify 脚本，与主 statusline 的 [维护方式](#维护方式) 一致）。

## 与 claude-hud 切换对比

> 本节**跨两脚本**：`/statusline-mine` 现在一并恢复主行（`statusLine`）与 subagent 面板行（`subagentStatusLine`）两个字段，故独立为顶层节置于文末。

Claude Code 的 **plugin 机制不能声明主 `statusLine`**（官方 plugins-reference：plugin 的 settings.json 只支持 `agent` / `subagentStatusLine`）。所以 claude-hud（`jarrodwatts/claude-hud`）不是「叠加一个 statusLine」，而是靠 `/claude-hud:setup` 命令**改写 `~/.claude/settings.json` 里那唯一的 `statusLine.command`**——本质是覆盖同一字段，谁最后写谁生效，不存在优先级/冲突问题。

> **注（2026-07-13 核实）**：`/claude-hud:setup` 只写/替换 `statusLine.command`，**完全不碰 `subagentStatusLine.command`**（它的「子代理跟踪」是把子代理状态汇总成主状态栏内嵌的一行文字，而非接管原生 Task 面板逐行渲染）。故切到 hud 只影响主三行；本仓库的 [Subagent 面板行](#subagent-面板行)（`subagent-statusline.sh`）照常生效、不受影响。

**方向对应（无 dispatcher，两个方向各管各的）：切到 hud = `/claude-hud:setup`；切回本脚本 = `/statusline-mine`（一并恢复主行 + subagent 面板行两字段）。** 两者都是改 `settings.json` 里对应的 `command` 字段，`statusLine` / `subagentStatusLine` 均**热重载、无需重启**，下一次刷新事件即生效。

> **生效时机（已实测核实，2026-07）**：Claude Code 用 file watcher 监听 `settings.json`，改动会**热重载**进内存（并触发 `ConfigChange` hook）；statusLine 又是事件驱动重渲染（新 assistant 消息 / `/compact` / permission mode 变更 / vim mode 切换）。所以改完 `.statusLine.command` **无需重启**，等下一次刷新事件即生效——发一条消息就能触发。官方 settings 文档只显式把 `model` / `outputStyle` 归为「启动期读取、需重启」，statusLine 不在其列（文档对 statusLine 沉默，结论以实测为准）。**重启只是「万一 watcher 没触发刷新」的兜底**，不是前提。

- 切到 claude-hud：`/claude-hud:setup`（选 “Replace it with claude-hud”）。首次需先 `/plugin marketplace add jarrodwatts/claude-hud` → `/plugin install claude-hud`（WSL 建议 `mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude` 规避 EXDEV）。setup 会自动备份 `settings.json.bak.<时间戳>`，并把旧命令原文存到 `~/.claude/plugins/claude-hud/previous-statusline.txt`。
- 切回本脚本：`/statusline-mine`（user 级自定义命令；真实文件 `~/.claude/statusline/statusline-mine.md` 在本仓库、经 `~/.claude/commands/` 下同名软链被发现；扁平命名、非 plugin）。它用 `jq` **一并**把 `.statusLine.command` 改回 `bash …/statusline-command.sh`、把 `.subagentStatusLine.command` 改回 `bash …/subagent-statusline.sh`（两字段各自 `type` 缺失时顺带用 `//=` 补回），先写临时文件再原子 `mv`，其余所有设置一个不动。一条命令恢复「主行 + subagent 面板行」全套。**为何连 subagent 一起设**：`subagentStatusLine` 虽无 claude-hud 之类竞争者覆盖（见上「注」），但 plugin 机制**允许**声明它（plugins-reference：plugin settings.json 支持 `agent` / `subagentStatusLine`），故顺手纳入以防未来某插件改写、并保持「切回我的全套」语义对称；改动仅在原 `jq` 里多一个字段赋值。`/statusline-mine` 只负责「切回我的脚本」这一个方向，不试图捕获/复现 hud 命令。兜底手段仍可用：`cp $(ls -t ~/.claude/settings.json.bak.* | head -1) ~/.claude/settings.json`，或从 `previous-statusline.txt` 读回旧命令。

**注意**：`CLAUDE_HUD_DISABLE=1 claude` 只在「claude-hud / 空白」间切，**不会回退到本脚本**；且若在 shell profile 里 export 了它会全局静默 claude-hud。改 `.statusLine.command` / `.subagentStatusLine.command` 均**无需重启**、下一次刷新事件即热生效（见上；重启仅作兜底）。
