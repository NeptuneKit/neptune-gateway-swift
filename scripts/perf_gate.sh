#!/usr/bin/env bash
set -euo pipefail

export NEPTUNE_GATEWAY_PERF_GATE=1

exec swift test --filter PerformanceGateTests/testGatewayStoreHandles100kConcurrentIngestAndQuery
