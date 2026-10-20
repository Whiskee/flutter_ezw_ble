## 0.0.1

* Keep Android high-reliability PHY requests under the RSSI adaptive policy at GATT readiness and OTA entry; preserve direct 2M requests in ordinary mode.
* Report iOS stalled-write `remainingPending` after failed-batch cleanup so the SDK can distinguish a cleared RAW window from other queued writes without weakening real-ACK recovery.
* Gate synchronous iOS CoreBluetooth peripheral retrieval behind the active App lifecycle and defer exact auto-reconnect owners across inactive/process-exit windows.
## Unreleased

- Add default-off iOS native Debug logging with lazy formatting, independent of
  BLE/Trace ownership. Preserve error diagnostics; Android accepts the new API
  without changing its logging behavior.
