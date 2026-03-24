# neptune-gateway-swift

NeptuneKit v2 gateway current implementation: GRDB-backed SQLite ingest, query, source aggregation, retention, and condition-based long polling.

## Runtime Stack

- HTTP server: Vapor
- CLI parsing: ArgumentParser
- SQLite persistence: GRDB

## Current Capabilities

- `POST /v2/logs:ingest`
- `GET /v2/logs`
- `GET /v2/metrics`
- `GET /v2/sources`
- `GET /v2/health`
- `GET /v2/gateway/discovery`

`/v2/logs:ingest` supports:

- `application/json` single record
- `application/json` array payload
- `application/x-ndjson`

`/v2/logs` currently supports:

- filters: `limit`, `beforeId`, `afterId`, `platform`, `appId`, `sessionId`, `level`, `contains`, `since`, `until`
- formats: `json`, `ndjson`, `text`
- `format=text` returns one record per line as `timestamp<TAB>level<TAB>platform<TAB>message`
- long polling: `afterId + waitMs`
  - returns immediately when a record newer than `afterId` is ingested
  - times out after `waitMs` and then re-runs the same query once
- CLI log proxy commands:
  - `logs proxy ios stream`
  - `logs proxy ios show`
  - `logs proxy android logcat`
  - `logs proxy harmony hilog`

`/v2/metrics` currently returns:

- `ingestAcceptedTotal`
- `sourceCount`
- `droppedOverflow`
- `totalRecords`

`/v2/sources` aggregates by:

- `platform`
- `appId`
- `sessionId`
- `deviceId`

## Current Limits

- retention defaults to `maxRecordCount=200000` and `maxAge=14d`, both configurable via the application entrypoint
- persistence no longer uses handwritten `SQLite3` C API bindings; schema/migration/query execution is handled through GRDB

## Run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway
```

Optional environment variables:

- `NEPTUNE_HOST` default `127.0.0.1`
- `NEPTUNE_PORT` default `18765`

## 构建/分发 CLI

优先使用 SwiftPM 的成熟构建链：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build -c release --product neptune-gateway
```

如果需要生成可分发的发布包，使用仓库脚本：

```bash
./scripts/build-cli-release.sh
```

脚本会优先通过 `xcrun` 选择当前 Xcode 安装里的 Swift 工具链；如果环境里没有 `xcrun`，才回退到 `swift`。

脚本会：

- 通过 `swift build -c release --product neptune-gateway` 生成发布二进制
- 将产物复制到 `dist/cli-release/`
- 生成带版本号的二进制文件名
- 输出 `sha256` 校验文件和发布清单

默认产物示例：

- `dist/cli-release/neptune-gateway-<version>`
- `dist/cli-release/neptune-gateway-<version>.sha256`
- `dist/cli-release/neptune-gateway-<version>.release-info.txt`

自检模式只验证脚本依赖和包根目录，不会真正编译：

```bash
./scripts/build-cli-release.sh --self-check
```

## CLI Proxies

Serve the gateway:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway serve
```

### iOS Unified Logging

`logs proxy ios stream` 会实时运行系统 `log stream`，适合盯住新日志；`logs proxy ios show` 会运行 `log show`，适合拉历史区间或补查过去日志。两者都支持透传原生 `log` 参数，例如 `--predicate`、`--style`、`--info`。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy ios stream --app-id demo.app
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy ios show --raw --predicate 'subsystem == "com.demo.app"'
```

### Android logcat

`logs proxy android logcat` 直接代理 `adb logcat`。先确保 `adb` 可用并且设备或模拟器已连接，然后把需要的 `adb logcat` 过滤参数原样透传给命令。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy android logcat --gateway http://127.0.0.1:18765
```

### Harmony hdc hilog

`logs proxy harmony hilog` 代理 `hdc hilog`。先确认 `hdc` 已安装且设备在线，再透传 `hilog` 的过滤参数。命令默认按行转发到网关，也可以加 `--raw` 只做直通输出。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy harmony hilog --app-id demo.harmony
```

Use `--raw` to print proxied lines without ingesting them:

```bash
swift run neptune-gateway logs proxy ios show --raw
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
