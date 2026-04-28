# 自動歌詞同期 実装計画（v2）

## 1. 目的と方針

`TXT` 歌詞を音源と自動同期して `LRC` 編集を支援する機能を、現行の旧実装（`internal/lyricssync/`）を全面破棄したうえで再設計・再実装する。

### 設計の核

- **ASR が認識した文字列はタイミング抽出専用**として扱い、表示文字列には**ユーザー入力歌詞のみ**を使う。これにより誤字混入を構造的に排除する。
- **ボーカル分離 → ASR → アラインメント** の三段パイプライン。
- アラインメントは **音素 DP ＋多言語文埋め込みベクトル** の併用で、サビ繰り返しや誤認識に強くする。
- 対応言語は **日本語＋英語**。
- 重い処理は **Python sidecar** に分離。Go 側は薄いプロキシに留める。
- **クロスプラットフォーム前提**で Python 同梱管理（macOS / Windows）。
- 将来的に macOS 専用版を **Swift + CoreML** で書き直すことを構造的に許容する（後述）。

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
  server/app_lyrics.go: AutoSyncLyrics(req) ─┐
                                              ↓ JSON over stdin
                              [Python sidecar: lyrics_sync]
                                  ├─ stage1_separate.py  (Demucs v4 htdemucs)
                                  ├─ stage2_asr.py       (faster-whisper, word ts)
                                  └─ stage3_align.py     (phoneme DP + sentence-embedding)
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

### Python ランタイム同梱管理

- ビルド時に `uv` で各 OS 向けに仮想環境を作成し、配布物に同梱する。
- 初回起動時に `~/Library/Application Support/UX-Music/python-venv`（macOS）/ `%APPDATA%\UX-Music\python-venv`（Windows）へ展開。
- ユーザー環境の `python3` には依存しない。
- これにより Windows 版でも同じパイプラインがそのまま動作する。

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
| **P1** | Python sidecar スケルトン（`Request` 受領 → ダミー `Result` 返却）。Go から spawn・stdin/stdout・タイムアウト・stderr 進捗中継 | sidecar I/O 単体テスト（Go・Python 双方） |
| **P2** | Stage1 ボーカル分離（Demucs htdemucs） | `test_separate.py`（短音源 fixture） |
| **P3** | Stage2 ASR（faster-whisper `medium` 既定）、word-level timestamp JSON | `test_asr.py` |
| **P4** | Stage3 アライナを音素 DP のみで実装。行レベル時刻を出す | テーブル駆動: 既知の Whisper JSON ＋歌詞 → 期待 `AlignedLine` |
| **P5** | 埋め込みベクトルによる行アラインメント追加、サビ反復対応 | サビ繰り返し曲で精度比較 |
| **P6** | 進捗イベント `lyrics-sync-progress` の Go→JS 配信、`lrc-editor.ts` ボタンに進捗表示 | 結合 |
| **P7** | モデル初回 DL 同意ダイアログ・キャッシュ管理・容量表示 | UI |
| **P8** | Windows ビルドで同等動作を検証（uv 同梱、モデルキャッシュパス、ffmpeg 同梱） | クロスプラットフォーム回帰 |
| **P9** | 旧実装テスト削除確定、版を `PhaseVer+1-a` に繰り上げ | regression |

## 6. 将来計画: macOS 専用 Swift + CoreML 版

Python sidecar 版で機能と精度が安定したのち、macOS 環境向けに **Swift + CoreML** で書き直すことを将来計画として明記しておく。

### 動機

- Apple Silicon の Neural Engine を直接活用し、レイテンシとメモリを大幅に削減する。
- Python ランタイムを同梱しないことでアプリサイズと初回起動時間を縮める。
- ユーザー環境への依存をさらに減らす。

### 想定構成

- `ux-music-sidecar/swift/lyrics_sync/`（新規）に Swift CLI を配置。
- ボーカル分離: Demucs を `coremltools` で `.mlpackage` 化し読み込み。
- ASR: [WhisperKit](https://github.com/argmaxinc/WhisperKit)（CoreML 最適化済み・word timestamp 対応）。
- 埋め込み: multilingual-e5-small を CoreML 化。
- 音素化: 日本語は OpenJTalk の Swift バインディング、英語は CMU dict ベースの軽量実装。

### 切替方針

- `Request` / `Result` JSON 契約は Python 版と完全互換に保つ。
- Go 側 `AutoSyncLyrics` がプラットフォームと設定を見て Python sidecar / Swift sidecar を切り替えるだけにする。
- Windows 版は引き続き Python sidecar、macOS 版は Swift sidecar が既定、という配置を可能にする。

この前提があるため、Python 版の段階でも sidecar I/O 仕様（JSON 入出力・進捗 stderr）は将来の Swift 実装でそのまま再現できる単純さを保つこと。

## 7. 確認済み事項

- 旧 `internal/lyricssync/` は main 上で削除して良い（退避ブランチを残す）。
- Whisper 既定モデルは **`medium`**。
- Python ランタイムは **同梱管理**。Windows でも同じパイプラインを動かすことを優先する。
- macOS 専用 **Swift + CoreML 版**は将来計画として保持する。
