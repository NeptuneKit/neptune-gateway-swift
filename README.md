# neptune-gateway-swift

NeptuneKit v2 gateway current implementation: relay-first architecture.  
Gateway ingests upstream logs and serves query/dispatch APIs, while log records are queried from online clients and aggregated in gateway.

## Runtime Stack

- HTTP server: Vapor
- CLI parsing: ArgumentParser
- Relay query coordinator: `GatewayClientLogRelay`
- Runtime counters: `GatewayRuntimeStats`

## Current Capabilities

- `POST /v2/logs:ingest`
- `GET /v2/logs`
- `POST /v2/ui-tree/inspector`
- `GET /v2/ui-tree/inspector`
- `GET /v2/ui-tree/snapshot`
- `GET /v2/metrics`
- `GET /v2/sources`
- `GET /v2/health`
- `GET /v2/gateway/discovery`

`/v2/logs:ingest` supports:

- `application/json` single record
- `application/json` array payload
- `application/x-ndjson`

`/v2/logs` currently supports:

- fan-out query to online callback clients
- filters: `cursor`, `length`, `platform`, `appId`, `sessionId`, `level`, `contains`, `since`, `until`
- formats: `json`, `ndjson`, `text`
- `format=text` returns one record per line as `timestamp<TAB>level<TAB>platform<TAB>message`
- partial upstream failures are returned in `meta.partialFailures` without changing HTTP `200`
- CLI log proxy commands:
  - `clients list`
  - `logs`（默认输出全部在线设备日志）
  - `logs --stream --device-id <id>`（按设备反推平台做本地代理）

`/v2/metrics` currently returns:

- `ingestAcceptedTotal`
- `sourceCount`
- `retainedRecordCount`
- `retentionMaxRecordCount`
- `retentionMaxAgeSeconds`
- `retentionDroppedTotal`

`/v2/sources` aggregates by:

- `platform`
- `appId`
- `sessionId`
- `deviceId`

## Current Limits

- query result size is controlled by `length`（为空表示返回全部）
- fan-out latency depends on callback client responsiveness

## Run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune
```

Optional environment variables:

- `NEPTUNE_HOST` default `127.0.0.1`
- `NEPTUNE_PORT` default `18765`

## UI Tree Mock 数据

将 `neptune-inspector-h5` 里的真实 inspector 样本转换为网关模型 `ViewTreeRawIngestRequest`：

```bash
./scripts/sync-ui-tree-mocks.sh
```

输出目录：`mocks/ui-tree/`

## 构建/分发 CLI

优先使用 SwiftPM 的成熟构建链：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build -c release --product neptune
```

如果需要生成可分发的发布包，使用仓库脚本：

```bash
./scripts/build-cli-release.sh
```

脚本会优先通过 `xcrun` 选择当前 Xcode 安装里的 Swift 工具链；如果环境里没有 `xcrun`，才回退到 `swift`。

脚本会：

- 通过 `swift build -c release --product neptune` 生成发布二进制
- 将产物复制到 `dist/cli-release/`
- 生成带版本号的二进制文件名
- 输出 `sha256` 校验文件和发布清单

默认产物示例：

- `dist/cli-release/neptune-<version>`
- `dist/cli-release/neptune-<version>.sha256`
- `dist/cli-release/neptune-<version>.release-info.txt`

## GitHub Release 发布

正式发布入口是 `.github/workflows/release-cli-tag.yml`。

触发方式有两种：

1. 向仓库推送 `v*` 格式的 tag，例如 `v1.2.3`。
2. 在 GitHub Actions 页面手动执行 `Release CLI (tag)` workflow，并填写 `tag_name`。

workflow 会：

- 在执行发布前校验 tag 必须符合 `v1.2.3` 或 `v1.2.3-rc.1` 这类语义化版本格式，不合法会直接失败
- 先用 `git log` 生成一个简要 changelog 片段，并作为 release body 前置内容
- 使用 `./scripts/build-cli-release.sh` 生成发布二进制、`sha256` 文件和发布清单
- 将 `dist/cli-release/` 下的产物上传到对应 GitHub Release
- 自动生成 Release notes
- 当配置了 Homebrew 发布参数时，自动执行 `./scripts/publish-homebrew-formula.sh` 更新 tap 仓库中的 `Formula/neptune.rb`

发布到 Release 的文件包含：

- `neptune-<version>`
- `neptune-<version>.sha256`
- `neptune-<version>.release-info.txt`

### Homebrew 自动发布配置

`Release CLI (tag)` workflow 会在创建 GitHub Release 后尝试发布 Homebrew Formula。  
默认发布到 `linhay/homebrew-tap`，需要在仓库设置中至少配置 token：

- Actions Variables:
  - `HOMEBREW_TAP_REPO`：可选，默认 `linhay/homebrew-tap`
  - `HOMEBREW_FORMULA`：可选，默认 `neptune`
- Actions Secrets:
  - `HOMEBREW_TAP_TOKEN`：可推送到 tap 仓库的 token

workflow 会基于本次 tag 生成下载地址：

- `https://github.com/<release_repo>/releases/download/<tag>/neptune-<tag>`

并写入 tap 仓库 `Formula/<formula>.rb`，随后自动提交并推送。

自检模式只验证脚本依赖和包根目录，不会真正编译：

```bash
./scripts/build-cli-release.sh --self-check
```

## CLI Proxies

Serve the gateway:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune serve
```

List online clients from gateway:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune clients list --format text
```

Text format output:

```text
- [ios-com.neptunekit.demo.ios] 0A9C614E-1DC9-4B0F-AB80-11448EAE708E
```

YAML output grouped by `deviceId`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune clients list --format yml
```

### Unified Stream Proxy

`logs`（无 `--device-id`）会持续拉取网关 `GET /v2/logs`，输出全部在线设备日志。

`logs --stream --device-id <id>` 会根据 `--device-id` 在 `GET /v2/clients` 中反推平台，再自动选择对应系统日志命令：

- iOS -> `log stream`
- Android -> `adb logcat`
- Harmony -> `hdc hilog`

可选附加过滤：`--app-id`、`--session-id`。  
`--raw` 可只打印原始日志，不上报网关。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune logs
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune logs --stream --device-id 0A9C614E-1DC9-4B0F-AB80-11448EAE708E
```

## Test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

GitHub Actions 会在 `push` 到 `main` 和 `pull_request` 时自动跑同样的 `swift test`。
手动触发 workflow 时可勾选 `perf_gate` 运行 100k 性能门禁。

## Performance Gate

The performance gate is opt-in and does not run during the default test suite.
It ingests 100,000 records concurrently, verifies the records remain queryable,
and checks that record IDs stay unique and strictly increasing.

Run it directly:

```bash
NEPTUNE_GATEWAY_PERF_GATE=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter PerformanceGateTests/testGatewayStoreHandles100kConcurrentIngestAndQuery
```

Or use the wrapper script:

```bash
./scripts/perf_gate.sh
```
