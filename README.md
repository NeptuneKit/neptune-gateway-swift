# neptune-gateway-swift

NeptuneKit v2 gateway current implementation: in-memory ingest, query, source aggregation, and simplified long polling.

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
- formats: `json`, `ndjson`
- simplified long polling: `afterId + waitMs`

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

- storage is in-memory only; restart loses all records
- `format=text` is not implemented and returns `400`
- long polling is a simple retry loop, not a condition-based notifier
- no SQLite retention, overflow, or backpressure policy yet

## Run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run neptune-gateway
```

Optional environment variables:

- `NEPTUNE_HOST` default `127.0.0.1`
- `NEPTUNE_PORT` default `18765`

## Test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```
