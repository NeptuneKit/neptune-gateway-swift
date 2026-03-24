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

## CLI Proxies

Serve the gateway:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway serve
```

Proxy Apple unified logging:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy ios stream --app-id demo.app
```

Proxy Android logcat:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway logs proxy android logcat --gateway http://127.0.0.1:18765
```

Proxy Harmony hilog:

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
