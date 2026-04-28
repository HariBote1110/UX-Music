# 自動歌詞同期 実装計画（v2）

## 1. 目的と方針

`TXT` 歌詞を音源と自動同期して `LRC` 編集を支援する機能を、現行の旧実装（`internal/lyricssync/`）を全面破棄したうえで再設計・再実装する。

### 設計の核

- **ASR が認識した文字列はタイミング抽出専用**として扱い、表示文字列には**ユーザー入力歌詞のみ**を使う。これにより誤字混入を構造的に排除する。
- **ボーカル分離 → ASR → アラインメント** の三段パイプライン。
- アラインメントは **音素 DP ＋多言語文埋め込みベクトル** の併用で、サビ繰り返しや誤認識に強くする。
- 対応言語は **日本語＋英語**。
- 重い処理は sidecar に分離し、**macOS は Swift + CoreML を既定**、**Windows は Python sidecar を既定**とする。Go 側は薄いプロキシに留める。
- **クロスプラットフォーム前提**で `Request` / `Result` JSON 契約を固定し、実装言語差分を sidecar 内へ閉じ込める。
- Python 実装は移行期間と非 macOS 向けフォールバックとして維持し、macOS では段階的に **Swift + CoreML** へ寄せる。

## 2. 既存資産の処遇

### 廃棄対象（main 上で削除、`archive/old-lyricssync` ブランチに退避）

- `internal/lyricssync/whisper_runner.go`（whisper CLI 直叩き）
- `internal/lyricssync/vocal_ml.go`（Demucs を Go から `exec`）
- `internal/lyricssync/align.go`（文字列ベース単調整列）
- `internal/lyricssync/syncer.go` の前処理・タイムアウト・フォールバック多段構造
- 上記の対応するテスト（`*_test.go`）
- `markdown/Task.md` の旧セクション「Task: CoreML 前提 TXT 自動歌詞同期」

### 維持する契約（フロント無改修のため）

- `internal/lyricssync/types.go` の `Request` / `AlignedLine` / `Result` JSON 形
- `server/app_lyrics.go` の `AutoSyncLyrics(req) (Result, error)`
- `src/renderer/js/features/lrc-editor.ts` の `runAutoSync()` 動線
- `src/renderer/js/core/env-setup.ts` の `lyrics-auto-sync` invoke ルート

## 3. アーキテクチャ

```
[Wails Go]
  server/app_lyrics.go: AutoSyncLyrics(req)
      └─ internal/lyricssync runtime resolver
            ├─ macOS + Swift runtime available
            │     ↓ JSON over stdin
            │   [Swift sidecar: lyrics-sync-swift]
            │     ├─ WhisperKit / CoreML ASR
            │     ├─ CoreML embedding alignment
            │     └─ vocal separation migration target
            └─ fallback
                  ↓ JSON over stdin
                [Python sidecar: lyrics_sync]
                  ├─ stage1_separate.py
                  ├─ stage2_asr.py
                  └─ stage3_align.py
                              ↓ JSON
                    [Go] プロセス監視・タイムアウト・進捗イベント中継のみ
                              ↓
                          [Result]
```

### Python sidecar

- 配置: `ux-music-sidecar/python/lyrics_sync/`
- エントリ: `python -m lyrics_sync --request -`
- 入出力: stdin から `Request` JSON、stdout に `Result` JSON、stderr に進捗 `{stage, percent}` を 1 行 1 イベントで出力
- 依存: `demucs`, `faster-whisper`, `sentence-transformers`, `pyopenjtalk`（日本語音素化）, `g2p-en`（英語音素化）

### Swift sidecar

- 配置: `ux-music-sidecar/swift/lyrics-sync/`
- エントリ: `lyrics-sync-swift --request -`
- 入出力: Python sidecar と同じく stdin/stdout/stderr JSON 契約を厳守する。
- 役割:
  - `WhisperKit` / CoreML を使った ASR
  - 現段階ではセグメント時刻からの**簡易単調整列 + 補間**
  - 将来的な埋め込み整列 / 音素整列 / ボーカル分離の Swift 実装受け皿
- 現在は `WhisperKit` でセグメント抽出を行い、Swift 内で歌詞行へのヒューリスティック整列を返す。高精度な埋め込み整列は次段で移植する。

### Python ランタイム同梱管理

- ビルド時に `uv` で各 OS 向けに仮想環境を作成し、配布物に同梱する。
- 初回起動時に `~/Library/Application Support/UX-Music/python-venv`（macOS）/ `%APPDATA%\UX-Music\python-venv`（Windows）へ展開。
- ユーザー環境の `python3` には依存しない。
- これにより Windows 版でも同じパイプラインがそのまま動作する。
- macOS では Swift runtime が有効な場合、この同梱 Python はフォールバック用途に限定する。

### 初回モデルダウンロード（オンライン）

| モデル | 用途 | 既定 | 概算 |
|---|---|---|---|
| Demucs `htdemucs` | ボーカル分離 | 固定 | ~80 MB |
| faster-whisper | ASR | **`medium`**（既定） / `large-v3-turbo` / `small` を設定で切替 | ~1.5 GB |
| `intfloat/multilingual-e5-small` | 文埋め込み（行アラインメント） | 固定 | ~120 MB |

- 初回 DL 前にユーザー同意ダイアログを表示。
- 進捗は Wails イベント `lyrics-sync-progress` で UI に配信。
- キャッシュ先と容量は設定画面で確認・削除できるようにする。

## 4. アラインメント詳細

1. **音素正規化**
   - ユーザー歌詞行を言語判定（CJK 比率）し、日本語は `pyopenjtalk` でモーラ列、英語は `g2p-en` で ARPAbet に変換。
   - Whisper の word 出力も同様に音素化。
2. **行境界の粗推定（埋め込み）**
   - Whisper のセグメント文と歌詞行を multilingual-e5 でベクトル化。
   - コサイン類似度行列に対し**単調制約付き DP** で行→セグメント対応を確定。
   - サビ繰り返しの誤対応を抑制。
3. **行内タイミング（音素 DP）**
   - 各行の担当セグメントに対し、音素列を DTW で対応付け。
   - 行の `start` = 最初の音素時刻、`end` = 最後の音素時刻。
4. **未マッチ行の補間**
   - 前後マッチ行の時間差から線形補間し `Source: "interpolated"`。
   - 楽器のみ区間は `Source: "interlude"`。

## 5. 段階的ロードマップ（TDD）

| Phase | 内容 | テスト起点 |
|---|---|---|
| **P0** | `markdown/lyrics-sync-plan.md` 確定、旧 `internal/lyricssync/` を `archive/old-lyricssync` に退避コミット後、main から削除。`markdown/Task.md` 旧セクション置換 | 旧テスト削除 |
| **P1** | Go 側に runtime resolver を追加し、Swift / Python sidecar の選択層を導入 | Go 単体テスト |
| **P2** | Swift sidecar スケルトン（`Request` 受領 → ダミー `Result` 返却） | `swift build` / ダミー実行 |
| **P3** | Python sidecar を現行フォールバックとして維持しつつ、macOS で opt-in 実行可能にする | sidecar I/O 結合 |
| **P4** | Swift Stage2 ASR（WhisperKit / CoreML）と簡易単調整列を実装 | 既知音源で timestamp 比較 |
| **P5** | Swift Stage3 アライナ（埋め込み + 音素整列）へ置換 | テーブル駆動テスト |
| **P6** | Swift 側の進捗イベントとモデル管理を統合 | UI / 結合 |
| **P7** | ボーカル分離を Swift / CoreML 実装またはネイティブ連携へ移行 | 短音源 fixture |
| **P8** | macOS を Swift 既定、Python を fallback に切替 | 回帰 |
| **P9** | Windows / fallback 導線と版管理を整理 | regression |

## 6. macOS 既定実装: Swift + CoreML

### 動機

- Apple Silicon の Neural Engine を直接活用し、レイテンシとメモリを大幅に削減する。
- Python ランタイムを同梱しないことでアプリサイズと初回起動時間を縮める。
- ユーザー環境への依存をさらに減らす。

### 想定構成

- `ux-music-sidecar/swift/lyrics-sync/`（新規）に Swift CLI を配置。
- ボーカル分離: Demucs を `coremltools` で `.mlpackage` 化し読み込み。
- ASR: [WhisperKit](https://github.com/argmaxinc/WhisperKit)（CoreML 最適化済み・word timestamp 対応）。
- 埋め込み: multilingual-e5-small を CoreML 化。
- 音素化: 日本語は OpenJTalk の Swift バインディング、英語は CMU dict ベースの軽量実装。

### 切替方針

- `Request` / `Result` JSON 契約は Python 版と完全互換に保つ。
- Go 側 `AutoSyncLyrics` はプラットフォームと設定を見て Python sidecar / Swift sidecar を切り替えるだけにする。
- Windows 版は引き続き Python sidecar、macOS 版は Swift sidecar を既定目標とする。

この前提があるため、Python 版の段階でも sidecar I/O 仕様（JSON 入出力・進捗 stderr）は将来の Swift 実装でそのまま再現できる単純さを保つこと。

## 7. 確認済み事項

- 旧 `internal/lyricssync/` は main 上で削除して良い（退避ブランチを残す）。
- Whisper 既定モデルは **`medium`**。
- Python ランタイムは **同梱管理**。Windows でも同じパイプラインを動かすことを優先する。
- macOS 側は **Swift + CoreML** への移行を継続し、Python sidecar は fallback として扱う。
