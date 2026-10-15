## 0.0.1

* Batch Android receive-data, connection-status and logger delivery through one FIFO main-thread outbox (64 events per drain), retaining payload/identity and isolating released engine lifetimes.
* Route native write failures through the same main-thread boundary; keep type=2 per-packet logcat while summarizing Dart logs every 5 seconds, with rate-limited outbox delay diagnostics.
* Gate synchronous iOS CoreBluetooth peripheral retrieval behind the active App lifecycle and defer exact auto-reconnect owners across inactive/process-exit windows.
