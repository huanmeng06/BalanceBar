# Issue #489 城市解析修复与性能记录

2026-10-08，本轮沿用 PR #490。原 UTC 固定偏移 UI 入口已由用户取消，保留旧配置兼容性。

## 提交规则与回归证据

- 删除「仅剩一个模糊候选就保存」的规则。只有精确城市名称、完整受支持 IANA ID 或主动确认的候选可直接提交。`York` 会进入城市解析；真实离线数据包含英国 York，而不是直接接受列表里的 New York。
- 偏好 setter 保存后同步递增版本；查询回调、延迟候选提交和最终保存检查版本及已挂载控件的选择。测试先排入旧回调，再保存 `.system`，刻意不调用 `apply`；另有 A→B→A 用例。
- 在线返回城市名与输入按 POSIX 大小写/音调规范化比较。唯一精确结果可自动保存；拼写修正、国家名等推测候选必须主动高亮/点击确认。离线命中的是完整规范化别名；同名结果不会按人口或地理距离猜测。
- GeoNames 资源保留 admin1 名称/代码。同名 Springfield 候选能区分 Illinois / Massachusetts 等州，且不会把同一国家内不同州的城市仅按时区合并。美国、加拿大、澳大利亚州/省有简繁中文名称；其他语言或未覆盖行政区保留数据源名称，国家名随 Locale 本地化。在线使用 Apple 的州/地区上下文并显示 IANA ID。
- 关闭跟随系统时冻结受支持地区，或冻结完全一致的受支持 GMT 偏移。无法表示的非标准偏移明确回退 UTC，字段显示 `UTC+00:00`，不会退回 system，也不会对原偏移取近似值。

351 项相关 XCTest 通过。最终扫描实现及回调 marked-text 防护再次通过 9 项聚焦回归；本地开发包编译和签名检查通过。测试不证明真实前台 AppKit 鼠标跟踪、输入法或 VoiceOver 验收通过。

## 解析器性能

环境：Apple M5，macOS 26.5.1，arm64，macOS 14 最低目标。独立探针直接编译生产 `CityTimeZoneResolver.swift`、加载实际生产资源；支持地区白名单用与 AppPreferences 相同的窄类型投影，预热白名单后开始记录。查询 Locale 为 en_US。进程冷启动，未清除文件系统缓存。耗时包含解压、匹配与格式化，不包含在线网络请求、整个应用启动和 GUI 渲染。

使用 `task_vm_info.phys_footprint` 测物理内存，`/usr/bin/time -l` 测进程峰值；查询置于 autoreleasepool 中。峰值为整个探针进程的绝对值，增长相对于查询前基线，不是整个 BalanceBar 的峰值。

| 实现／编译方式 | 首次夏延查询 | 后续查询 | 查询后物理内存增长 | 峰值物理内存 | 峰值 RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| a150ecb4 的长期别名索引，-O | 570 ms | <0.02 ms | 68.9 MiB | 71.9 MiB | 81.2 MiB |
| 本轮扫描，开发包同等 -Onone | 20.5 ms | 8.5–12.2 ms | 6.5 MiB | 9.7 MiB | 21.3 MiB |

连续 50 次开发编译查询后，物理内存增长为 6.7 MiB，峰值物理内存 9.8 MiB、峰值 RSS 21.4 MiB；未出现随查询次数线性增长的全量索引驻留。

本轮移除了常驻全量索引。后台串行解压到有上限的缓冲区，用系统 `memmem` 搜索完整别名，只解码命中的记录；退出时释放缓冲区。控件只缓存最多 16 个查询的结果。分配器仍可保留部分页，因此查询后内存增长并非零。

新资源：34,155 条记录，解压后 6,408,615 bytes，压缩后 2,425,628 bytes。资源生成脚本重复生成后的 SHA-256 完全一致：`2205f3dbdc302b2e6796e932e7157238c30f616ebcab5421ad44e2f22fa96b3a`。

复现（仓库根目录）：

```sh
probe_dir="$(mktemp -d)"
mkdir -p "$probe_dir/CityPerf.app/Contents/MacOS" "$probe_dir/CityPerf.app/Contents/Resources"
cp Resources/CityTimeZoneData.lzfse "$probe_dir/CityPerf.app/Contents/Resources/"
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" scripts/benchmark-city-time-zone.swift Sources/Services/CityTimeZoneResolver.swift -framework MapKit -framework CoreLocation -o "$probe_dir/CityPerf.app/Contents/MacOS/CityPerf"
/usr/bin/time -l "$probe_dir/CityPerf.app/Contents/MacOS/CityPerf" 50
```

将 `-Onone` 换成 `-O` 可复测优化构建。资源可用 `scripts/generate-city-time-zone-data.swift` 从 GeoNames cities15000 和 admin1CodesASCII 重建；来源与许可随资源打包。

## 尚待前台验收

- 鼠标点击候选、点击弹窗外部、连续上下键、Return/Escape，以及查询结束与开关切换的连续操作。
- 中文/日文组合输入、灰色无结果行的原生显示及 VoiceOver 语义。
- 狭窄设置页与 Global Search 投影、真实应用首次查询的响应性。
- 在线 Apple 查询在本机此前返回服务错误；用可用服务环境验证精确/模糊与同名结果。离线测试不依赖该服务。

保持 Request Changes / 待 GUI 验收；本记录不授权合并、版本提升或生产部署。
