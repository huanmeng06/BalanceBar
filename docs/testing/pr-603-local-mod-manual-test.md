# PR #603：合入 main 后的本地 Mod 人工测试

本指南适用于尚未公开发布的 BalanceBar Mod。运行命令前进入 **#603 的原工作树**，不是主仓库、历史 INT-2 或已合并 #605 的工作树。

同步记录：#605 的合并提交 `adf51108`；本轮 main 为 `8afa7986`（#606）；正常 merge 提交 `79a6fdfd`，无冲突。应用版本继承 main 的 `1.7.39 / 208`，未额外升版本。测试包位置为此工作树的 `build/dev/BalanceBar-dev.app`，Bundle ID `com.huanmeng06.BalanceBar.dev`。

## 1. 准备与安装边界

- 本机 Claude Code 已核验为 `2.1.291`；最低支持版本 `2.1.287`。Desktop **Code** 本地会话也需使用支持 Mod 的运行时。测试本机 Local 会话，不是 Chat、Cowork、Cloud 或 SSH。
- CC Switch 中 Claude 选择官方 OAuth 账号；CLI `/status`、Desktop Code 和 BalanceBar 当前账号应一致。先让 BalanceBar 获得一次有效的官方额度与周期基线；如出现429，等待既有冷却，不反复强刷或改限流。
- 本地目录 marketplace + `--scope user` 是真实跨项目安装。`--plugin-dir`、`--scope local/project` 不等同于 #603 管理的用户级安装，不能拿它们验证“已安装”。
- 当前 App 的一键安装仍使用 `huanmeng06/BalanceBar`，没有本地来源覆盖。公开默认分支缺少该 marketplace 时，一键安装失败属于未发布阶段的预期边界；本指南用本地路径验证真实安装与数据通路。
- 下文不会让你编辑 Claude 配置、关闭账号/周期验证、伪造可信快照或删除凭据。CLI 命令由你执行；本次构建没有替你安装/卸载 Mod。
- user-scope Mod 对本用户的 Claude Code 会话生效；收件箱由开发版和生产版共同读取，测试不是隔离用户环境。

在 #603 工作树的 Terminal 中定义变量（后续代码块沿用同一 Terminal）：

```sh
BB603_WORKTREE="$(git rev-parse --show-toplevel)"
BB603_INBOX="$HOME/Library/Application Support/BalanceBar/inbox"
BB603_NOTES="$(mktemp -d "${TMPDIR:-/tmp}/BalanceBar-603-manual.XXXXXX")"
export BB603_WORKTREE BB603_INBOX BB603_NOTES

git branch --show-current   # 必须为 codex/issue-597-mod-user-install
git rev-parse HEAD
claude --version
claude plugin list --json
claude plugin marketplace list --json
```

若已有本插件/同名来源，先记录它原来的 scope 和来源。需要测完整“未安装→安装”时，可以先执行第8节的**本插件 user scope**卸载命令；不要清空整个 plugins 目录或删除 settings.json。

保存不含配置明文的基线，用于对比 statusLine/其它插件是否保持不变：

```sh
bb603_settings_summary() {
python3 - <<'PY'
import hashlib, json
from pathlib import Path
p = Path.home()/'.claude/settings.json'
d = json.loads(p.read_text()) if p.exists() else {}
def digest(v):
    return hashlib.sha256(json.dumps(v, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
other = {k:v for k,v in d.get('enabledPlugins', {}).items()
         if k != 'balancebar-mod@balancebar-mods'}
print(json.dumps({'statusLineSHA256': digest(d.get('statusLine')),
                  'otherEnabledPluginsSHA256': digest(other)}, sort_keys=True))
PY
}
bb603_settings_summary > "$BB603_NOTES/settings-before.json"
```

测试期间不修改其它插件；这个摘要仅比较 statusLine 与其它插件开关，不保存 token/对话/配置明文。

## 2. 启动准确的测试 App、先测未安装/错误回退

先从菜单退出其它 **开发版** BalanceBar，再打开此工作树的包；不要误开 #604 或历史 INT-2 的旧包：

```sh
codesign --verify --deep --strict "$BB603_WORKTREE/build/dev/BalanceBar-dev.app"
open -n "$BB603_WORKTREE/build/dev/BalanceBar-dev.app"
```

1. 设置 → 高级，顶部应为独立「Claude 实时增强」卡片。通用刷新无重复 Mod 行。
2. 未安装状态点「查看说明」：应是 INT-2 小窗，图标、居中标题、副标题、四条图标要点，底部左复制/右稍后与安装；Esc稍后，Return安装。
3. **未发布边界**：可点一次“一键安装”，检查真实CLI错误与复制回退/重试；当前公开来源若缺清单，不要求这一步安装成功。不要为做绿更改来源、限流或快照。
4. 记录错误后关闭窗口，按第3节本地安装。已安装后若需要查看失败旧页，关闭重开即可看到当前管理状态；检测有30秒节流，可等30秒后重开管理或重启测试App。

本地完整安装成功不等于 App 的公开源一键安装成功；公开源路径仍需未来默认分支具备清单后补验。

## 3. 本地安装命令（不需要发布）

Mod 自身不会创建收件箱，直接 CLI 安装前先安全准备默认目录；存在但所有者不符/不可写时停止，不使用 sudo/chown 强改：

```sh
python3 - <<'PY'
import os
from pathlib import Path
p = Path.home()/'Library/Application Support/BalanceBar/inbox'
if p.exists():
    if not p.is_dir() or p.stat().st_uid != os.getuid() or not os.access(p, os.W_OK):
        raise SystemExit('inbox 已存在但不是当前用户可写目录；先查明原因，不要 sudo 强改')
else:
    p.mkdir(parents=True, mode=0o700)
print('inbox ready:', p)
PY

# 指向本 #603 工作树根目录，其清单通过 source: ./mod 定位插件。
claude plugin validate "$BB603_WORKTREE/.claude-plugin/marketplace.json"
claude plugin validate "$BB603_WORKTREE/mod" --strict
claude plugin marketplace add "$BB603_WORKTREE" --scope user --json
claude plugin install balancebar-mod@balancebar-mods --scope user --json
claude plugin list --json
claude plugin marketplace list --json
```

预期：两份校验 PASS；add/install 的JSON报告成功；列表中 `id=balancebar-mod@balancebar-mods`、`scope=user`、`enabled=true`；marketplace 指向本工作树。不要把 `scope=local/project` 当成全局安装，也不要改成旧原型目录。注册本地源可能替换原同名来源，所以上一步应记录其原来源。

若列表为停用，可使用 UI 复制的启用命令或运行：

```sh
claude plugin enable balancebar-mod@balancebar-mods --scope user --json
```

回到高级卡片，等检测更新后应显示“已安装，等待…数据”，不应仅因 install 成功就显示实时正常。手动 CLI 安装不是 App 自身安装回调，不保证当下还停留的说明窗立即更新；超过30秒后关闭重开管理/重启测试App触发检测。

## 4. CLI 真实数据闭环

1. 保持测试 App 运行，Claude 为官方 OAuth 账号且已取得有效官方周期基线。
2. 在一个无重要文件的目录新开 CLI 会话。之前自己设置过 `BALANCEBAR_MOD_INBOX` 时，不要把数据写到另一个测试目录；下例仅为本次新进程去掉该覆盖：

```sh
env -u BALANCEBAR_MOD_INBOX claude
```

3. 会话内 `/status` 核对账号；`/plugin` 中确认 BalanceBar Mod 已启用。若提示权限，查看实际请求后按测试意图确认。
4. 发送“只回复 OK，不要读写文件”，等待本轮结束，再对话1–2轮。`session.measure` 有可用 usage/rateLimits 时才会写快照。
5. 用另一个 Terminal 运行以下只读摘要（不输出邮箱/token/对话内容），前后对比 `updated_at` 是否前进：

```sh
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home()/'Library/Application Support/BalanceBar/inbox'
files = sorted(p.glob('balancebar-mod-*.json'), key=lambda x:x.stat().st_mtime, reverse=True)
if not files:
    print('no Mod snapshots yet')
for f in files[:3]:
    try:
        d = json.loads(f.read_text())
        print(json.dumps({'file': f.name, 'source': d.get('source'),
            'updated_at': d.get('updated_at'),
            'has_account_hash': bool(d.get('account',{}).get('email_hash')),
            'window_kinds': [x.get('kind') for x in d.get('windows',[])],
            'five_hour': d.get('five_hour'), 'seven_day': d.get('seven_day')}, ensure_ascii=False))
    except Exception as e:
        print(f.name, type(e).__name__)
PY
```

6. 文件出现只是“写入成功”。只有 BalanceBar 原管线接受当前账号/周期的数据，高级状态才应为正常并显示最近数据时间。若显示账号/周期拒绝，不能算PASS；先检查账号一致及官方基线。
7. 安装流程仍在等待且管理窗开着时，真实受理后绿色成功页停留2秒关闭。手动CLI安装后重开的窗口通常已是管理页，不要求再次出现安装流程的成功动画。
8. 验证关闭重开仍是当前管理；复制 `/reload-plugins` 的小图标出现勾选反馈，粘贴正确。已有会话可运行 `/reload-plugins` 后对话；如果重载失败，直接新开会话补验。

## 5. Desktop Code 真实数据闭环

1. 使用 **Claude Desktop → Code**，不是 Chat/Cowork。选择本机 Local 环境及一个测试目录；不使用 Cloud/SSH。
2. 退出旧的 Desktop Code 会话，新建会话；必要时完整退出并重启 Claude Desktop。核对它的运行时支持 Mod，以及所用账号与 BalanceBar 一致。
3. 插件管理里确认 `balancebar-mod@balancebar-mods` 用户级启用（位置可能在输入框 + → Plugins/Add plugins → Manage）。如果不显示，先检查同一用户配置/组织策略；不要复制Mod文件到其它目录来伪造安装。
4. 对话1–2轮，运行上面的只读快照摘要。应有新 `updated_at`，BalanceBar 经真实受理后更新正常状态/最近时间。
5. 暂停CLI会话再做Desktop测试，方便判断新时间来自Desktop。旧的正在运行会话可能不加载新插件；重开会话后再次观察。
6. 以后修改本地 Mod 代码，CLI 可新会话/reload；Desktop可能持有安装缓存，最可靠的补验方式是仅卸载本插件后按第3节重新安装，再重开Desktop本地会话。不要假设普通刷新一定换掉运行中的旧模块。

## 6. 功能、异常与回归检查表

| 场景 | 怎么测 | 应观察到 |
| --- | --- | --- |
| UI/搜索 | 从其它页搜索 Mod、卡片标题、当前状态；打开/关闭说明及主窗 | 定位高级独立卡片；子窗无残留；重开正确；不抢其它应用焦点 |
| 浅深色/语言 | 12语言，重点德/俄，缩放小窗和改变高度；Tab/Shift-Tab、Return/Esc、VoiceOver | 文案/按钮不裁切、长内容可滚动；卸载不作为危险默认动作 |
| 安装命令失败 | 第2节测试公开源错误 | 真实原因/CLI摘要/复制/重试；不显示实时成功 |
| 停用与启用 | `claude plugin disable balancebar-mod@balancebar-mods --scope user --json`；重开检测；再enable并新会话 | 停用状态准确，有复制启用入口；再次真实受理后恢复 |
| 10分钟无数据 | 停止发起新回复，让Claude进程保持运行10分钟以上，再关闭重开管理触发检测 | 静默排查与reload/新会话建议；不伪造新数据时间 |
| 账号切换 | 仅在你有可切换的测试账号时：先A受理，再把BalanceBar切B，CLI暂留A后交互；再对齐到B | 旧正常证据清空，账号拒绝；同账号且新周期有官方基线后恢复。不要发配置/token作为反馈 |
| 周期验证 | 等自然换周期或出现真实周期拒绝后看提示；不人工篡改当前用户快照 | 未验证周期不被当成实时成功；此边界也有自动化测试覆盖 |
| 重装证据 | 完成一次卸载，再本地安装；尚未新对话时观察 | 不继承旧安装的正常证据；新快照被受理后恢复 |
| Codex/main回归 | 切到Codex额度卡，检查重置倒计时及数字更新 | #606的倒计时/数字修复保留，不被Mod UI影响 |

CLI缺失、旧版本、收件箱权限不足不要通过改名真实claude或chmod真实数据目录强行复现。相关路径已做注入测试；需要真实故障注入时用单独测试用户环境另行测试。自然未具备的场景标记“未测”，不填PASS。

## 7. 安装中关闭重开与公开源的一键安装验收

本地CLI安装可验证插件安装、用户级检测、可信状态、文件写入及CLI/Desktop消费，但**不能替代当前App公开源一键安装成功**。

- 当前可实测：一键安装真实失败回退、进行中关闭不崩溃、重开显示真实结果/错误，以及本地CLI成功后进入管理。
- 当前已有自动化覆盖：安装/卸载进行中关闭重开保留进度、失败重试、证据清理、可信成功2秒关闭。
- 发布/默认分支具备根清单之后：用App“一键安装”重新跑添加来源→安装插件→等待可信数据→真实受理；在两条命令执行期间关闭/重开，确认后台操作不被取消。不要将这项提前写为真实PASS。

## 8. 安全卸载、校验其它配置与复原

优先在管理窗口测试：点击卸载先出现确认；Return应取消、Esc应关闭；只有再次明确点击卸载才执行。进行中关闭/重开保留进度。完成后检测未安装、再次进入可安装。

等价的CLI清理仅操作本插件/自有marketplace的 **user scope**：

```sh
claude plugin uninstall balancebar-mod@balancebar-mods --scope user --json
claude plugin marketplace remove balancebar-mods --scope user --json
claude plugin list --json
claude plugin marketplace list --json

bb603_settings_summary > "$BB603_NOTES/settings-after.json"
diff -u "$BB603_NOTES/settings-before.json" "$BB603_NOTES/settings-after.json"
```

预期：用户级插件/来源消失，statusLine与其它插件开关摘要不变（Claude可能重排JSON键序，所以比较语义摘要）。不要省略marketplace remove的 `--scope user`，不要加 `--prune`。

结束旧Claude会话，再新开CLI/Desktop Code会话：不再持续产生新的Mod时间戳。卸载不会删除已有快照或用户文件；残留文件不是卸载失败证据。官方额度路径按原缓存/限流恢复，不能要求零等待强刷。

如测试前已有本插件或同名来源且需要恢复，按起初记录的原来源重新 `marketplace add <原来源> --scope user` 并安装/启用本插件。不要整份覆盖 settings.json，以免丢失并行产生的其它用户设置。

## 9. 故障定位与反馈

- 无文件：先确认user-scope启用、新会话、支持的Code运行时；检查可用usage/rateLimits、默认HOME/收件箱及未设置别处的`BALANCEBAR_MOD_INBOX`。
- 有文件但未正常：核对账号、周期和官方基线；文件存在≠被受理；查看高级状态中的真实拒绝原因。
- Desktop无文件但CLI正常：确认是本机Code、同账号/同配置、不是旧缓存/旧会话，也没有组织策略屏蔽模块。
- 公开源安装失败：先按本地安装流程验通；网络错误/manifest_missing不与本地安装PASS混为一谈。
- 反馈格式：`PASS/FAIL/未测 + App源码SHA + CLI/desktop运行时版本 + 场景/步骤 + 实际/预期 + 脱敏截图`。不要提交token、完整Claude配置或对话内容。

## 验证来源

安装命令已对照本机 Claude Code 2.1.291 的 `--help` 和当前 `ModInstallPlan`/`ModSyncDetector`；根清单和mod严格校验通过，`claude plugin test ./mod`为9 PASS。

官方参考：[本地marketplace的创建与安装](https://code.claude.com/docs/en/plugin-marketplaces)、[Desktop Code插件与本地环境](https://code.claude.com/docs/en/desktop)。本项目的账号hash、收件箱、可信受理、30秒检测及10分钟静默行为，以本分支源码为准。
