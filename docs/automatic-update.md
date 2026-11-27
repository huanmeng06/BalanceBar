# Automatic update recovery

BalanceBar keeps the previous app bundle until the replacement reaches
`applicationDidFinishLaunching`. If the system refuses to launch the new app,
the updater leaves the backup in place for manual recovery.

The backup is stored at:

`~/Library/Application Support/<bundle identifier>/Updater/Backups/BalanceBar.previous-<version>.app`

To restore it, quit BalanceBar, open Finder, and choose **Go → Go to Folder**.
Enter `~/Library/Application Support/<bundle identifier>/Updater/Backups/`.
Copy the `BalanceBar.previous-<version>.app` bundle back to the location where
BalanceBar is installed, replacing the failed `BalanceBar.app`. Keep the backup
until the restored app has opened successfully.

If BalanceBar reaches its startup code but exits before
`applicationDidFinishLaunching`, the next launch attempt restores the previous
bundle and exits. Open BalanceBar again to start the restored version. If macOS
refuses to start the new executable before that code runs, use the Finder steps
above.

Manual in-app installs keep their rollback bundle beside the installed app as
`.BalanceBar.previous-<unique id>.app` until the replacement reaches
`applicationDidFinishLaunching`.

Idle installation uses the same backup. The updater waits up to 60 seconds
for the replacement to confirm startup. On failure it restores and opens the
previous app and suppresses further idle attempts for that update version.

## 手动验收

在装有 Xcode 的 Mac 上，从仓库根目录运行下列命令。每次运行都会启动独立的 **BalanceBar Update Test** 并在 Finder 选中。基准版本为 `90.0.0`，更新版本为 `90.1.0`。

### 退出安装

1. 运行 `./scripts/test-automatic-update.sh`。在 Dashboard 的 **通用** 页依次打开 **自动下载新版本** 和 **自动安装新版本**，等 **检查更新** 显示「90.1.0 已下载，等待安装」。
2. 点红色按钮关闭 Dashboard，再从测试 App 的菜单栏打开它。确认仍在等待安装。
3. 在菜单栏选择 **退出 BalanceBar**。等安装完成，确认 App 保持退出。切回 Finder，双击同一个测试包，在 **关于** 页确认版本为 `90.1.0`。

### 闲时安装

1. 运行 `./scripts/test-automatic-update.sh idle`。打开下载和安装两个开关，等 **检查更新** 显示已下载。
2. 保持 Dashboard 开着且不操作 35 秒，确认没有安装。然后关掉 Dashboard 和菜单，保持电脑唤醒，至少 35 秒不碰键盘、鼠标或触控板。
3. 确认测试 App 的菜单栏图标重新出现。打开 Dashboard 的 **通用** 页，确认「已在你离开时更新到 90.1.0」。关掉 Dashboard 再打开，确认提示已消失。

### 只下载，手动安装

1. 运行 `./scripts/test-automatic-update.sh idle`。只打开 **自动下载新版本**，等 **检查更新** 显示「90.1.0 已下载，等待安装」。
2. 关闭 Dashboard 和菜单，保持电脑唤醒且 35 秒不操作。确认旧版仍在运行。选 **退出 BalanceBar**，再从 Finder 打开测试 App，确认 **关于** 页仍为 `90.0.0`。
3. 返回 **通用**，等缓存恢复后点 **立即安装**。确认 App 重启并运行 `90.1.0`。
4. 用一个新测试实例验证开关联动。打开两个开关，再关闭下载，确认安装置灰但仍显示打开。重新打开下载，安装恢复可用。切到 Beta，确认两个开关都是关闭状态。

### 失败场景和清理

1. 运行 `./scripts/test-automatic-update.sh tampered`。打开 **自动下载新版本**，确认 **检查更新** 显示验证失败及 **重试**，版本保持 `90.0.0`。
2. 运行 `./scripts/test-automatic-update.sh read-only`。打开两个开关，等下载完成后关闭 Dashboard 和菜单，保持电脑唤醒，等至少 35 秒。确认旧版重新打开，检查更新显示安装失败。再次关窗并等 35 秒，确认同一版本没有再次闲时重启。
3. 重新运行 `./scripts/test-automatic-update.sh read-only`。打开两个开关并等下载完成，在菜单选择 **退出 BalanceBar**。确认一次点击即可退出。等安装程序结束后，从 Finder 重开测试 App，确认仍为 `90.0.0`，**检查更新** 持续显示需要手动安装。
4. 退出测试 App，等安装程序结束后，运行 `./scripts/test-automatic-update.sh clean` 清理测试包、本地更新素材和专用设置。

使用干净的测试实例重复上述步骤。视觉验收覆盖宽窄窗口、浅色和深色、高对比度、键盘及 VoiceOver。macOS 14 与 Intel 可使用同一命令实测。

从旧草稿版本升级时，单开关的值按通道迁移为下载偏好。自动安装默认关闭。
