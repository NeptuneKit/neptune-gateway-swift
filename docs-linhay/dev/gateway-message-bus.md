# GatewayMessageBus 设计说明

## 结构
- `GatewayMessageBus`
  - 负责根据 `GatewayBusClient.preferredTransports` 选择适配器
  - 在单客户端发送失败时按优先级顺序回退
  - 在批量发送时聚合 `delivered / acked / timeout`
- `ClientTransportAdapter`
  - 统一接口：`send(_ envelope: BusEnvelope, to client: GatewayBusClient)`
- `HTTPCallbackAdapter`
  - 复用现有 `/v2/client/command` HTTP 回调模型
- `WebSocketAdapter`
  - 当前为占位实现，保留后续接入在线 SDK WebSocket 的扩展点
- `USBMuxdHTTPAdapter`
  - 先向 `/var/run/usbmuxd` 发送 `Connect` plist 报文
  - 成功后在同一 socket 上发送 HTTP/1.1 POST

## 关键约束
- `BusAck.transport` 与 `BusAck.recipientID` 允许客户端省略，由 Gateway 在适配器层补齐，保证总线内部统一。
- `ClientSnapshot` 会回显 `preferredTransports/usbmuxdHint`，便于 inspector 或调试端确认 Gateway 实际保存的路由信息。
- 默认传输优先级为 `httpCallback`，避免对旧客户端产生隐式行为变化。

## 测试覆盖
- `GatewayMessageBusTests`
  - 适配器选择与回退
  - ACK 聚合
- `USBMuxdHTTPAdapterTests`
  - 字节序
  - 握手成功后 HTTP 透传
  - 握手失败
- `GatewayRoutesTests`
  - register 新字段校验
  - register 回显新字段
