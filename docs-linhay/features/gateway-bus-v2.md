# Gateway /v2 双向总线

## 背景
`/v2` 侧原先只有 HTTP callback 下发路径，WebSocket inspector 命令汇总与实际传输绑定过紧，不利于扩展 usbmuxd / WebSocket 等多传输链路。

## 本次收敛
- `POST /v2/clients:register` 统一为以下字段：
  - `callbackEndpoint`: 必填，必须是绝对 `http(s)` URL
  - `preferredTransports`: 可选，声明客户端期望的传输优先级
  - `usbmuxdHint`: 当 `preferredTransports` 包含 `usbmuxdHTTP` 时必填
- 命令下发统一使用 `BusEnvelope`
- 客户端 ACK 统一使用 `BusAck`
- Gateway 统一通过 `GatewayMessageBus` 选择适配器并在失败时回退

## 传输策略
- `httpCallback`: 默认传输，兼容现有 `/v2/client/command`
- `webSocket`: 预留适配器，当前可编译但默认不实际投递
- `usbmuxdHTTP`: 通过 `/var/run/usbmuxd` 建链后转发 HTTP 请求

## 验收场景
1. 当客户端声明 `preferredTransports=[webSocket,httpCallback]` 且 WebSocket 不可用时，Gateway 自动回退到 HTTP callback。
2. 当多个客户端同时接收命令时，Gateway 能聚合 ACK 结果并保留 timeout 计数。
3. 当 register 请求缺失 `callbackEndpoint`，或声明 `usbmuxdHTTP` 但未提供 `usbmuxdHint` 时，Gateway 返回 `400`。
4. 当 usbmuxd 握手成功时，Gateway 能继续发送 HTTP 请求并解析 `BusAck`；握手失败时返回投递失败。
