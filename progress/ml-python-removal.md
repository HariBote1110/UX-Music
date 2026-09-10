# デスクトップML/Python機能の廃止

## Decision

デスクトップバックエンドをGo + TypeScriptに限定するため、Pythonの歌詞自動同期（Demucs/faster-whisper）、SwiftのWhisperKit歌詞同期、Python CLAP音声埋め込み・ムード検索、llama-server（Gemma）によるムード特集生成を廃止した。手動歌詞の `GetLyrics`、`SaveLrcFile`、`HandleLyricsDrop` は維持する。MTP、CDリッピング、終了時のトレイ破棄とLaunchAgent復元も維持し、終了処理からはMLプロセス停止だけを除去した。

## Alternatives considered

- ML機能を無効化フラグで残す案は、Python/Swiftランタイムやモデル契約が配布物とAPIに残るため採用しなかった。
- Swift側だけを残してPythonをフォールバックにする案は、同期精度が目標に届かず、不要な実装・依存を保持するため採用しなかった。
- CLAP検索とGemma特集を別機能として残す案も、ユーザーがML機能を放棄したため採用しなかった。

## Constraints

- Wails生成の `src/renderer/wailsjs/` は手編集せず、サーバーAPI削除後に `wails generate module` で再生成する。
- `Shutdown` のトレイ破棄とLaunchAgent引き継ぎ復元の挙動は変更しない。
- MTPとCDリッピングは変更しない。MTPのlibusb未導入によるローカルビルド失敗は既存の環境制約として扱う。
- 過去のML検討記録は履歴として保持し、進捗インデックスでは廃止と明記する。
