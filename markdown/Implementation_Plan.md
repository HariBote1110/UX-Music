# Implementation Plan: macOS 向け自動歌詞同期の Swift / CoreML 最適化

## 目的
自動歌詞同期の重い処理を、macOS では `Swift + CoreML` に寄せていく。既存の `Python sidecar` はすぐに削除せず、Windows と移行期間のフォールバックとして残す。

## 方針
1. **契約固定**
   - `internal/lyricssync/types.go` の `Request` / `Result` JSON 形を唯一の契約として扱う。
   - `server/app_lyrics.go` と `src/renderer/js/features/lrc-editor.ts` の導線は変えない。
2. **実行系分離**
   - Go 側で sidecar 解決層を設け、`python` と `swift` を選択可能にする。
   - ランタイム選択は設定または環境変数で制御し、非 macOS は常に Python を使う。
3. **macOS 最適化**
   - Swift 側は `WhisperKit` / CoreML を前提に構成し、将来的にボーカル分離と埋め込み整列も Swift 実装へ移す。
   - Apple Silicon の計算資源を優先し、Python 同梱と起動コストを縮小する。

## 実装ステップ
1. **仕様更新**
   - `markdown/features.md`
   - `markdown/requirement.md`
   - `markdown/lyrics-sync-plan.md`
   - `markdown/Task.md`
2. **Go 側の切替基盤**
   - `internal/lyricssync/syncer.go` から Python 固定解決を切り離す。
   - `internal/lyricssync` に sidecar runtime resolver を追加する。
   - `UX_MUSIC_LYRICS_SYNC_RUNTIME=python|swift|auto` を受け付ける。
3. **Swift sidecar スケルトン**
   - `swift/lyrics-sync/Package.swift`
   - `swift/lyrics-sync/Sources/LyricsSyncCLI/main.swift`
   - `stdin JSON -> stdout JSON` / `stderr progress JSON` の互換を実装する。
4. **検証**
   - Go テストで runtime 選択ロジックを確認する。
   - `swift build` で CLI のビルド可能性を確認する。
   - ダミーモードで JSON 契約が崩れていないことを確認する。

## この段階で扱わないこと
- Demucs / 埋め込み / 音素整列の完全 Swift 移植
- CoreML モデル同梱と初回ダウンロード UI の再設計
- Windows 側の sidecar 削除

## 完了判定
- macOS 向け Swift sidecar の差し込み口がコード上で成立している。
- ドキュメントが Python 中心の記述のまま残っていない。
- 既存 UI 契約を壊さずに、段階移行を続けられる状態になっている。
