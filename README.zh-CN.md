# cc-cache-warming

[English](README.md) · **简体中文**

<p>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
<a href="test.sh"><img alt="tests: 144 passing" src="https://img.shields.io/badge/tests-144%20passing-brightgreen"></a>
<img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-6E56CF">
<img alt="pure shell" src="https://img.shields.io/badge/pure-bash%203.2%2B-555">
</p>

**在最后一次真实任务结束后，把 Claude Code 主 Session 的 Prompt Cache 最多保温 6 小时；
回来继续工作时命中缓存读取，而不是整段重写。**

Claude 做完任务、你离开电脑后，后台 **Monitor** 会在每次缓存被触达后约 48 分钟，
往**同一个主 Session** 里发一条很短的 ping。ping 本身就是主对话的一个普通回合，
所以它的请求读取并续期的，正是你下一条消息要用的那份缓存。每次 ping 都会
**根据 transcript 里的真实 token 指标验证**；满 6 小时、发满 8 次，或出现任何异常，都会自动停下。

面向配置了 `promptCacheTtl: "1h"` 的 Claude Code（Claude Pro/Max 在套餐用量内默认就是 1 小时）。
纯 Bash 3.2+ 加 POSIX 工具实现：不依赖 jq 或 Python，不联网，不碰任何凭据。

---

## 工作原理

```
你："做 X"         ── UserPromptSubmit ─► 本回合 = 真实回合
Claude 干活 …      ── Stop ─────────────► 进入保温：real_at = touch = now
                                           deadline = now + 6h（只有真实回合会设置它）
你离开
   Monitor 一直睡到下一个 ping 时段（不耗 token，只读几个小文件）：
   touch + 48m ≤ now < touch + 55m ？ 缓存还值得保、而且还来得及
   └─► 输出 "[ccw:<nonce>] Automated prompt-cache keep-warm ping …"   = Ping Sent
         Claude Code 把它作为通知投递 ─► UserPromptSubmit 钩子 = 闸门
           太晚 / 不需要 / 已关闭 / 过期的 ping ─► 拦截：不产生任何模型请求
           否则 ─► ping 回合（PreToolUse 禁止一切工具）─► 回复 "ok"
         Stop（ping）─► 绝不改动截止时间，只排队等验证
   下一个 tick：只读 transcript 尾部，取这次 ping 请求的 usage
     缓存读取 ≥ 提示的 80%，且不少于主前缀大小         = Cache Hit Verified
     … 且距上次真实回合已超过一个 TTL                  = Main Session Warm Verified
     未命中 / 大规模重写 / 5m 档 / 换了模型 / 查不到 usage ─► 停止，等你下一次真实回合
   循环，直到缓存已覆盖到截止时间、发满 8 次，或满 6 小时
你回来：你这一回合的第一个请求同样会被检查 ─► Main Session Warm Verified（回归）
```

默认参数下，一段完整的离开期共 **7 次 ping**（约第 48、97、146、195、244、293、342 分钟）。
最后一次 ping 已经能让缓存撑过第 6 小时，所以不会再发第 8 次。8 次是硬上限。

### 怎么区分真实回合和 ping

每条 ping 都带一个随机 nonce。`UserPromptSubmit` 钩子认出它后
记下这次 ping 的 `prompt_id`；带同一个 `prompt_id` 的 `Stop` 就算作 ping，只有其他 `Stop` 才会
重新计时。真实任务、后台 Agent 结果、`/loop` 唤醒，以及本插件自己的 skill 都会开启新的 6 小时窗口，
ping 永远不会。

### 三级证据

| 级别 | 含义 | 依据 |
| --- | --- | --- |
| **Ping Sent** | Monitor 已发出 ping（钩子看到它送达，或拦下了它） | Monitor + `UserPromptSubmit` 钩子 |
| **Cache Hit Verified** | 这次 ping 的 API 请求有 ≥ 80% 的提示来自缓存读取，且读取量不少于主 Session 的前缀 | transcript 中该请求的 `cache_read_input_tokens` / `cache_creation_input_tokens` |
| **Main Session Warm Verified** | 命中发生在你上一次真实回合**一个 TTL 之后**：没有之前的 ping，这份缓存早该过期了。你离开回来后的第一个请求也会再验证一次 | 同上，再加时间条件 |

不会因为收到通知或模型回了 `ok`，就认为缓存续期成功。如果在 transcript 里找不到某次
ping 的 usage，保温直接停止（unverifiable）。

ping 就是*主* Session 的一个回合，既没有 Fork，也不会产生第二份缓存。它的请求就是对话前缀
原样加上一条短消息。验证时也会核对：读取量必须覆盖主前缀（≥ 上次真实请求提示量的 90%），
并且模型必须是这个 Session 的模型。

### 什么时候停（并且不再花钱）

| 条件 | 结果 |
| --- | --- |
| 距上次真实回合满 6 小时、发满 8 次，或缓存已覆盖到截止时间 | 本窗口结束 |
| 错过 ping 时段（电脑睡眠、Claude 忙、通知被挡） | **不补发**：停止，等下一次真实回合 |
| ping 送达过晚（距上次触达 ≥ TTL − 2 分钟） | 被钩子拦截，不发请求 |
| 缓存未命中或大规模重写（读取 < 50%；50–80% 的部分命中容忍一次） | 停止；如果按理缓存应该是热的，就在**所有 Session** 中**暂停**该 Claude Code 版本的自动 ping |
| ping 都命中了，你回来时却是冷的 | 暂停该 Claude Code 版本 |
| 出现 5m 缓存档（来自 usage，或 Claude Code 报告 `cache_ttl: "5m"`） | 停止 |
| `/model` 切换、压缩、`/clear`、恢复时缓存已过期 | 等下一次真实回合 |
| 上下文 < 4 万 token | 不值得保温 |
| `rate_limit` / `billing_error` / 认证类错误（`StopFailure`） | 停止 |
| `server_error` / `overloaded` / 网络问题 | 2 分钟后重试一次，再失败就停止 |
| ping 回合试图调用工具 | 拒绝（`PreToolUse`），`bypassPermissions` 下同样有效 |

### 休眠与墙钟时间

所有截止时间都是绝对的墙钟时间，所以息屏或睡眠期间 6 小时照样在走。ping 只在安全时段内发
（距上次触达 48–55 分钟）。唤醒后不会集中补发：每个时段最多一次，错过就结束本窗口。

**不会阻止熄屏。** 保温窗口生效期间，Monitor 在 macOS 上运行 `caffeinate -s -t <到截止时间>`：
它只在**接通电源**时阻止*系统*休眠，让网络和 Monitor 继续运行；显示器照常按节能设置熄灭
（`pmset` 显示 `PreventUserIdleDisplaySleep 0`）。用电池时它不起作用；到截止时间自动结束，
窗口一结束也会立即停止。合盖仍会让 Mac 睡眠。`CCW_CAFFEINATE=2` 改用 `-i`（电池下也生效），
`CCW_CAFFEINATE=0` 关闭。

### 多 Session

* 每个 Claude Code 进程一个 Monitor。状态按 Session 存放在
  `~/.claude/cc-cache-warming/sessions/<session-id>/`。
* 钩子会让 `procs/<claude-pid>` 始终指向该进程当前的 Session，因此 `/clear` 或进程内
  `/resume` 之后，Monitor 会跟到新对话上，旧对话的保温随之停止。
* 重新加载插件会启动新的 Monitor 并接管，旧的转入静默但不退出，因为 Claude Code
  会把 Monitor 退出变成一次模型回合。万一自己的"monitor ended"通知还是来了，钩子会拦下。
* 退出时的 `SessionEnd` 会停掉本进程的 Monitor 和 `caffeinate`，并且只杀确认是我们自己 Monitor 的 pid。

---

## 安装

从 GitHub 安装：

```
/plugin marketplace add AaronL725/cc-cache-warming
/plugin install cc-cache-warming@cc-cache-warming
```

从本地克隆安装（改代码后 `/reload-plugins` 即生效）：

```bash
git clone https://github.com/AaronL725/cc-cache-warming.git
claude plugin marketplace add ./cc-cache-warming
claude plugin install cc-cache-warming@cc-cache-warming
claude plugin list
```

装好后重启 Claude Code 或运行 `/reload-plugins`。每个交互式 Session 都会自动启动 Monitor，
第一个真实回合结束后开始保温。

要求：交互式 Claude Code CLI（已在 **2.1.308** 上验证）。插件 Monitor 不在 `-p`/SDK 会话、
Bedrock/Vertex/Foundry 上运行，设置了 `DISABLE_TELEMETRY` /
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` 时也不运行。插件不会改你的任何配置，
`promptCacheTtl: "1h"` 由你自己保持。

> 同一时间只运行一个缓存保温插件；多个保温器可能重复发送 ping，增加用量。

## 使用

| 需求 | 做法 |
| --- | --- |
| 查看状态 | `/cc-cache-warming:status` |
| 关闭**本 Session** 的保温 | `/cc-cache-warming:off`（立即生效，已排队的 ping 会被拒） |
| 重新打开 | `/cc-cache-warming:on`（下一次真实回合后重新开始） |
| **全局**关闭（总开关） | `bash <plugin>/scripts/cc-cache-warming-ctl.sh off-all`，或 `touch ~/.claude/cc-cache-warming/disabled` |
| 全部恢复（同时清除版本暂停） | `… cc-cache-warming-ctl.sh on-all` |
| 某个项目永不启用 | `touch <project>/.claude/cc-cache-warming-off` |
| 任何地方都不启用 | 在 `~/.claude/cc-cache-warming/config` 写 `CCW_ENABLED=0` |
| 看日志 | `… cc-cache-warming-ctl.sh log 50`，或 `tail -f ~/.claude/cc-cache-warming/sessions/<id>/log` |
| 所有 Session | `… cc-cache-warming-ctl.sh status --all` |

三个 skill 都设置了 `disable-model-invocation: true`，Claude 不会自行调用。它们通过 `!` 注入
执行 ctl 脚本，只花一个很小的回合；而且作为真实回合，会重新开启保温窗口。`<plugin>` 指克隆目录里的
`plugins/cc-cache-warming`，或 `~/.claude/plugins/cache/` 下的已安装副本。

## 配置

环境变量（Claude Code 启动时的环境）优先于 `~/.claude/cc-cache-warming/config`
（`KEY=VALUE` 行，只解析、不执行），再其次是默认值。Monitor 每个 tick 都会重读配置文件。

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CCW_ENABLED` | `1` | `0`/`false`/`no`/`off` 全部关闭 |
| `CCW_INTERVAL_SECONDS` | `2880` | 距上次缓存触达 48 分钟时 ping |
| `CCW_TTL_SECONDS` | `3600` | 主 Session 的缓存 TTL（`promptCacheTtl: "1h"`） |
| `CCW_SAFETY_SECONDS` | `300` | 晚于 TTL − 该值（55 分钟）就不再*发出* ping |
| `CCW_GATE_MARGIN_SECONDS` | `120` | 晚于 TTL − 该值才*送达*的 ping，被钩子拒绝 |
| `CCW_WINDOW_SECONDS` | `21600` | 距上次真实回合的硬性窗口（6 小时） |
| `CCW_MAX_PINGS` | `8` | 每个窗口的硬上限 |
| `CCW_TICK_SECONDS` | `60` | ping 前后的 Monitor 轮询周期 |
| `CCW_IDLE_TICK_SECONDS` | `300` | 无事可做时的轮询周期（等待 ping 时直接睡到预定时刻） |
| `CCW_MIN_CONTEXT_TOKENS` | `40000` | 提示量更小就不保温（Claude Code 自身约 2.7 万 token 的系统前缀本来就跨 Session 共享） |
| `CCW_HIT_PERCENT` / `CCW_PARTIAL_PERCENT` | `80` / `50` | 判定命中的读取占比 / 低于此值判为未命中 |
| `CCW_VERIFY_GRACE_SECONDS` | `180` | 最多等这么久，让 transcript 写出 ping 的 usage |
| `CCW_RETRY_SECONDS` / `CCW_MAX_ERRORS` | `120` / `2` | 临时性 API 错误的重试 |
| `CCW_TAIL_BYTES` | `1048576` | 每次验证读取的 transcript 字节数（从不读整个文件） |
| `CCW_CAFFEINATE` | `1` | macOS 窗口生效期间：`1` = 仅接电源时阻止系统休眠，`2` = 电池下也阻止，`0` = 关闭；任何档位都不阻止熄屏 |
| `CCW_LOG_MAX_BYTES` | `262144` | Session 日志超过该大小时截掉较旧的一半 |
| `CCW_PING_TEXT` | 见下 | `[ccw:<nonce>]` 标签后面的文字 |
| `CCW_STATE_DIR` | `~/.claude/cc-cache-warming` | 状态、日志、开关文件 |
| `CCW_RETENTION_DAYS` / `CCW_MAX_SESSIONS` | `7` / `200` | 闲置 7 天的 Session 目录，以及超出最新 200 个的目录，归档到 `archive/cc-cache-warming-<date>.tar.gz` |
| `CCW_ARCHIVE_KEEP_DAYS` / `CCW_HOUSEKEEP_INTERVAL` | `30` / `21600` | 归档 30 天后删除（`0` = 永久保留）；清理最多每 6 小时一次 |

默认 ping 文本，约 50 个输入 token，通常回复 3–5 个输出 token：

```
[ccw:1a2b3c4d] Automated prompt-cache keep-warm ping (cc-cache-warming). Not a task: do not use tools or resume earlier work. Reply with only: ok
```

时间约束：`INTERVAL + TICK < TTL − SAFETY`，参数组合不合理时脚本会自动修正。5 分钟 TTL
下保温不划算，看到 5m 缓存写入就会自动停止。

## 账号安全与成本

* **不碰凭据，不自己调 API。** 插件从不读取、导出或重放 OAuth token 或 key，
  不直接调用 API，也不冒充客户端。每次 ping 都是你自己的交互式 Claude Code Session 里的一个
  普通回合，走的是 Claude Code 官方文档里的插件 Monitor 机制。
* **有上限，且透明。** 每次离开最多 8 个短回合，最多持续到真实工作后 6 小时，不会无限循环。
  ping 文本直接说明自己是什么，*没有*为了看起来像真人而随机化：伪装自动化并不能降低风险，
  反而释放了错误的信号。唯一变化的是 nonce，供钩子识别 ping。
* **条款。** 订阅的使用规则可能变化；无人值守、消耗套餐用量的自动化属于灰色地带，请自行阅读
  Anthropic 最新的 Consumer Terms / Usage Policy 后判断。拿不准就 `ctl.sh off-all`。
  ping 和普通回合一样计入套餐用量；缓存读取是最便宜的一类请求（约 0.1× 输入价），
  一旦未命中会立即停止保温。
* **盈亏线。** 缓存读约 0.1×、1 小时缓存写约 2× 基础输入价，约 20 次 ping 才抵得上一次冷重写；
  这里一次离开最多 8 次。详见 [docs/COST.zh-CN.md](docs/COST.zh-CN.md)。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `monitor : not running` | Monitor 不可用（无头模式、Bedrock/Vertex/Foundry、关闭了遥测）或插件未加载：`claude plugin list`、`/reload-plugins` |
| `state : waiting for the first real turn` | 刚启动或刚恢复时的正常状态 |
| `stopped - context … < 40000` | Session 太小；确实想保温就调低 `CCW_MIN_CONTEXT_TOKENS` |
| 日志里有 `PING_UNDELIVERED` | 输入框里留着草稿时，Claude Code 会暂扣通知；离开前清空输入框 |
| `missed the ping slot … likely sleep` | Mac 真的睡了（合盖或断电），缓存本来也没了 |
| `BENCHED` | 某次 ping 或你的回归回合在本应命中时未命中，说明这个 Claude Code 版本的前缀有变化；升级 Claude Code 后用 `on-all` 清除 |
| `stopped - … 5m cache tier` | 检查设置里的 `promptCacheTtl: "1h"` |
| 全新 Session 的第一次 ping 是 `CACHE_PARTIAL` | 正常：Claude Code 最早的缓存标记落在会话启动上下文上，之后的 ping 会完整命中 |
| transcript 里能看到 ping 的回复 | 设计如此：ping 本身就是一个回合（`ok`），这样才能命中主缓存 |

每个决定都会带着原因写进 `sessions/<id>/log`（`ARMED`、`PING_SENT`、`PING_DELIVERED`、
`PING_BLOCKED`、`TOOL_DENIED`、`CACHE_HIT_VERIFIED`、`CACHE_PARTIAL`、
`MAIN_SESSION_WARM_VERIFIED`、`RETURN_COLD`、`STOP`、`DONE`、`BENCHED` 等）。

## 资源占用与上限

在 Apple 芯片 Mac 上用 /bin/bash 3.2 实测（`./test.sh` 中 20 次平均）：

| 路径 | 运行频率 | 开销 |
| --- | --- | --- |
| `PreToolUse` 钩子 | 每次工具调用 | **约 3 ms**：一次 bash 启动加一次目录匹配，然后 `exec cat` 读完 stdin（hook 提前关闭 stdin 会被 Claude Code 记为 EPIPE 错误）；只有 ping 回合进行中才运行完整逻辑 |
| `UserPromptSubmit` / `Stop` 钩子 | 每个回合一次 | 约 12 ms，不开子 shell，没变的状态不重写 |
| Monitor tick | 空闲时 5 分钟一次；等待 ping 时直接睡到预定时刻；只有 ping 前后才每分钟一次 | 约 6 ms；只会启动 `date` 和 `sleep` 两个进程 |
| 读 transcript | 每次 ping / 回归检查一次 | 只读最后 256 KB（必要时最多 1 MB），从不读整个文件 |

钩子以 exec 形式运行（没有 `sh -c` 包装），`SessionStart` 为 async。

磁盘上的所有内容都有上限：
- **日志：** 每个 Session 日志超过 256 KB 时截掉较旧的一半（Monitor 每小时检查一次，清理时也检查），`housekeep.log` 上限 64 KB。活跃使用的 Session 只在状态切换时记录 `ARMED`，不会每回合一行。
- **Session 目录：** 闲置 7 天或超出最新 200 个时归档；Claude 进程仍在运行的 Session 永不归档。
- **归档：** 保留 30 天后删除。
- **残留文件：** 已消失 Session 的 `off` 标记、过期的 ping 标记和临时文件会被清除。
- **进程映射：** Claude 进程退出后删除。

## 测试

```bash
./test.sh                       # 144 项检查，约 1.5 分钟，不需要 Claude
CCW_TEST_SHELL=/opt/homebrew/bin/bash ./test.sh
```

用模拟时钟（`CCW_NOW`）和按 Claude Code 真实记录格式构造的 transcript，驱动钩子和
`monitor --once`，覆盖以下场景：

- **完整 6 小时生命周期：** 7 次 ping 及其时刻、截止时间不变、7 次命中、6 次主 Session 验证、自动停止，以及回归检查；
- **调度：** 8 次上限、新真实任务重新计时、睡眠后不集中补发；
- **闸门：** 迟到和过期的 ping 被拦截、工具被拒、钩子不输出任何内容；
- **缓存异常：** 未命中并按版本暂停、部分命中只容忍一次、5m 档、模型切换、压缩、小上下文、由其他模型回复；
- **失败处理：** 额度错误、临时性重试、无法验证或未送达的 ping、被中断的回合；
- **Session 与运维：** 多 Session 隔离、`/clear`、各类开关、Monitor 结束通知、配置解析、真实后台 Monitor（stdout 静默、接管、随 Claude 退出、SessionEnd 绝不误杀他人 pid）、归档清理、打包检查。

设计所依赖的钩子和通知行为，都在 Claude Code 2.1.308 的真实交互会话里实测过：
- Monitor 输出的一行会以 `<task-notification>…<event>LINE</event>` 的形式到达 `UserPromptSubmit`；
- 在那里 `block` 就不会产生模型请求；
- `Stop` 与 `UserPromptSubmit` 共享 `prompt_id`；
- `PreToolUse` 的 deny 在 `bypassPermissions` 下有效；
- Monitor 退出会额外消耗一个回合；
- Monitor 命令里的 `${CLAUDE_SESSION_ID}` 为空，但 `CLAUDE_CODE_SESSION_ID` 和 `CLAUDE_PID` 会导出。

本插件的端到端实跑（Haiku，压缩时间参数）结果：
- Bash 工具调用被拒；
- ping 的缓存读取占比 99%；
- 超过 TTL 的那次 ping 和回归回合都得到了 Main Session Warm Verified。

## 已知限制

* 每次 ping 会在对话里留下两条很短的记录（通知和 `ok`）；带思考的模型可能为此花几十个思考 token。
* Claude Code 可能在收到多条通知后自行生成离开期间的"recap"，那次调用来自 Claude Code，不是插件发起的。
* 输入框里留着草稿会挡住通知，这时 ping 会被拒绝或跳过，但绝不会迟发。
* 真正睡眠的 Mac（合盖、无电源）没法 ping，窗口会直接结束。
* transcript 格式不是公开 API；一旦格式变化，验证会安全失败（unverifiable），保温随之停止。
* 被中断的回合（Esc）不会触发 `Stop`，插件会在 5 分钟后从 transcript 中识别出来。

## 许可证

MIT，见 [LICENSE](LICENSE)。
