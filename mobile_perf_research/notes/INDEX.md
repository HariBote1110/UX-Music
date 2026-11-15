# Mobile パフォーマンス Research ノート索引

- [device-energy-harness-2026-10.md](device-energy-harness-2026-10.md) — iPhone Air 実機で Power Profiler をアプリ1プロセスに attach して電力を測る再現手順（`tools/device_energy.sh`、別バンドル ID の計測ビルド）。発熱対策 A〜E の前後比較: A はバックグラウンド再生中のポーリング 65回→0回、B は一時停止中 CPU 約-36%。ただし端末が充電扱いでパワーインパクト/電池%は 0、C は未確定。
- [thermal-static-review-2026-10.md](thermal-static-review-2026-10.md) — 発熱要因の静的レビュー。最有力は Control タブのポーリングが LazyTabRoot の opacity 保持で onDisappear せずバックグラウンド再生中も2秒周期で継続する件と、一時停止後も止まらない4Hz位置タイマー＋Now Playing情報の全書き換え。YouTube は非表示中も Wi-Fi 時は既定画質でデコード継続。実測未了。
- [baseline-microbench-2026-08.md](baseline-microbench-2026-08.md) — 静的レビューの疑い箇所をXCTest `measure{}`で実測したベースライン。isDownloadedはn=100→400→800で二次スケーリング（O(n²)）を確認、DownloadManager init(n=800)は平均183ms、アートワークのサムネイルデコード優位性は合成画像では有意差なし（要再検証）。追記: isDownloadedのstem辞書化（O(1)化）を実装し再計測、n=800で平均5219.87ms→19.64ms（265.7倍高速化）を確認。
- [static-review-2026-08.md](static-review-2026-08.md) — アプリ全体の静的パフォーマンスレビュー。最大の疑いは DownloadManager のディレクトリ全列挙（行ごと・O(n²)）。8 項目を重大度順に記録。実測は未了。
