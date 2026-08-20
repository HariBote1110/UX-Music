# INDEX

- go-heap-pprof.md — Goヒープ44MB≒runtime.Sysと確認。ライブデータは11〜22MBのみでJSONデコード/Wails IPCの一時アロケーションが最大、残りはHeapIdleスラックとランタイム固定コスト。単一の支配的サブシステムは無く仮説棄却
- baseline-footprint.md — Goプロセス約100MBの内訳確定（Goヒープ44MB＋native malloc 37MB＋定常15MB、駐機前後で不変）
