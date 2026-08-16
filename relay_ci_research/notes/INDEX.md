# relay_ci_research ノート索引

新しいものが上。

- [stale-cmd-wait-teardown.md](stale-cmd-wait-teardown.md) — `TestRemoteRelayEngine_MultipleConcurrentClientsBothReceiveBytes` が GitHub Actions の ubuntu-latest ランナーでのみ「両クライアント0バイト」で失敗していた件の原因調査。CI に `-race` で計測用の診断フックを仕込んだところ、直前のテスト（Single client）の ffmpeg stderr 読み取りゴルーチンが次テストの `Start()` 後もまだ生きていることを示すデータレースを検出。`relayEngine` の Start/Stop に世代（generation）の概念が無く、古いセッションの「ffmpeg 終了を待って Stop() する」ゴルーチンが新しいセッションを巻き込んで破棄しうる再入可能性バグと特定。世代カウンタで修正し、CI で3回連続グリーンを確認。仮説採択、GITHUB_ACTIONS スキップは解除済み。
