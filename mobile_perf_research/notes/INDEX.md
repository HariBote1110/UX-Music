# Mobile パフォーマンス Research ノート索引

- [baseline-microbench-2026-08.md](baseline-microbench-2026-08.md) — 静的レビューの疑い箇所をXCTest `measure{}`で実測したベースライン。isDownloadedはn=100→400→800で二次スケーリング（O(n²)）を確認、DownloadManager init(n=800)は平均183ms、アートワークのサムネイルデコード優位性は合成画像では有意差なし（要再検証）。
- [static-review-2026-08.md](static-review-2026-08.md) — アプリ全体の静的パフォーマンスレビュー。最大の疑いは DownloadManager のディレクトリ全列挙（行ごと・O(n²)）。8 項目を重大度順に記録。実測は未了。
