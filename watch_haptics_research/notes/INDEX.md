# watch_haptics_research ノート一覧

- [bass-onset-detector-design.md](bass-onset-detector-design.md) — iPhone 側の低音オンセット検出。22,050 Hz、2048/512 FFT、30〜150 Hz、log spectral flux、median+3×MAD、125 ms 抑制、30 秒チャンク＋1 秒オーバーラップの採用理由。
- [haptic-beat-feasibility.md](haptic-beat-feasibility.md) — Watch 触覚ビート同期の実現可能性。Core Haptics は watchOS 不可で `WKHapticType` の固定パターンのみと机上確認済み。連続発火の下限間隔・再生との共存・画面オフ継続・タイミング精度の仮説 H1〜H4 を実機で検証: 125ms 間隔でも区別可（H1 採用）、再生との併用可（H2 採用）、画面オフ継続は不可（H3 棄却済み）、遅延 p95 ≤ 3.8ms（H4 採用）。基調の振動は `failure`。本実装へ昇格
