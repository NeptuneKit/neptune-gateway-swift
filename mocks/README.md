# UI Tree Mocks

该目录用于网关快速调试 UI Tree 模型映射。

- `ui-tree/*-inspector.json`：各端真实 inspector 原始快照。
- `ui-tree/*-raw-ingest-request.json`：已转换为网关模型 `ViewTreeRawIngestRequest` 的请求体。
- `ui-tree/raw-ingest-requests.json`：三端请求体聚合数组。

更新方式：

```bash
./scripts/sync-ui-tree-mocks.sh
```

默认会从 `../neptune-inspector-h5/mocks/real/` 读取样本并做转换。

从 `*-raw-ingest-request.json` 生成标准 `ui-tree-snapshot.json`：

```bash
./scripts/build-ui-tree-snapshot-mock.sh
```
