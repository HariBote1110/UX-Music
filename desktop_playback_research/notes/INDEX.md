# desktop_playback_research ノート索引

新しいものが上。

- [park-resume-cold-state.md](park-resume-cold-state.md) — park復帰でWebView再生成→goStateゼロ初期化、初回ポーリング(1s遅延)までのコールドウィンドウ中の操作が無反応/0秒シークになる主因を特定。修正方向は初回tick即時実行によるシード。副因: initAppの非await初期化と早期操作の競合。実測未了

- [seek-playpause-freeze-static-review.md](seek-playpause-freeze-static-review.md) — シークバー停止/前曲位置固定・再生ボタン無反応の静的解析。独立バグ複合の仮説4本（A: 巻き戻り防止ガード誤発動、B: isSeeking スタック、C: embed mount サイレント失敗、D: goPollInFlight スタック）。実測未了。
