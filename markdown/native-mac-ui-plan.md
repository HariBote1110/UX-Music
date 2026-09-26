# 設計書: Mac 版 UI のネイティブ化（SwiftUI）と Wails 版の保守モード移行

**作成日:** 2026-09-27
**状態:** Phase 0 完了（2026-09-27、9 項目すべて合格・続行）。結果はブランチ `research/native-bridge-spike` の `native_bridge_research/notes/phase0-verdict.md`
**関連:** `markdown/appletv-servermode-plan.md`（単一バイナリ・`--serve`）、`progress/lan-api-v1.md`（LAN API v1 SSoT）、`markdown/plan-wails-audio-path-refactor.md`、`markdown/issue-wails-playback-ui-desync-unresolved.md`
**参考実装:** `~/GitHub/UX-Inkwell`（Rust コア＋SwiftUI/AppKit＋WinUI 3。知見は §11 にまとめた）

---

## 0. 結論（要約）

- **Rust へのリライトは行わない。** Go コア（`server/`・`internal/`・`pkg/`、本体約 2.6 万行＋テスト約 2 万行）は Mac・Windows 共通のまま残す。
- **Mac 版の UI だけを SwiftUI で新しく作る。** Go コアは `-buildmode=c-archive` で静的ライブラリにして Swift アプリにリンクし、**単一バイナリ・単一プロセス**を保つ。
- **Windows 版は現行の Wails 版を保守モードで残す。** 不具合修正とコア変更への追従だけを行い、UI の新機能は原則入れない。
- **ロジックは Go コアに寄せ、UI は描画だけの薄い層にする。** これを両 UI 共通の設計ルールとする。

## 1. 背景と動機

### 1.1 Web ベースである理由が薄れている

- Web UI は Electron 時代の名残で、今は Wails（WKWebView）上で動いている。音声エンジンはすでに Go + PortAudio（`pkg/audio`）にあり、Web が担っているのは UI だけ。
- Windows 版は「一応ある」程度の位置づけ（2026-09-27 ユーザー確認）。**クロスプラットフォームのために Web を選ぶ理由はもう小さい。**
- iOS・watchOS・tvOS はすでにネイティブ SwiftUI（`UX-Music-Mobile/`、Swift 約 1.9 万行）。

### 1.2 Web であることに起因するコスト（実績）

| 事象 | 記録 |
|---|---|
| 表示と実際の音がずれる。JS と Go が再生状態を二重に持っている | `markdown/issue-wails-playback-ui-desync-unresolved.md` |
| Electron 向けと Wails 向けで音声・設定の経路が分かれている | `markdown/plan-wails-audio-path-refactor.md` |
| バックグラウンド時に WebView のメモリを解放するため、Wails をフォークしている | メモリ `project_wails_fork`、`server/app_park.go` |
| 常駐メモリは本体約 65MB＋WebKit 約 100MB＝約 165MB。駐機（park）時のメモリ返却を別途調査した | `go_memory_research/notes/`、`native_bridge_research/notes/memory-footprint-vs-wails.md` |
| 同じ機能（歌詞スナップ）をデスクトップ（TS）とモバイル（Swift）で二重に実装・修正している | `d99d286d` / `45b767fa` |

### 1.3 Rust を採らない理由（判断記録）

これまでの主要な不具合は言語を替えても解決しない。

- libusb のリークは FFI 越しの資源管理の問題で、Rust でも起きる。
- 表示と音のずれは状態の二重管理が原因。
- デコーダのパニックは対処済み。

Rust の利点が効くのは「複数 OS からコアを本気で共有する」場合だけで、Windows が本気でない以上は元が取れない。Go の資産（Wails フォーク、go-mtpfs と hanwen-usb の replace、kkdai/youtube）と約 2 万行のテストを捨てるコストのほうがはるかに大きい。

## 2. 目標と非目標

### 目標

1. Mac 版を SwiftUI ネイティブ UI にし、WebView は YouTube 公式再生の埋め込みだけに限定する。
2. Go コアを Mac・Windows・`--serve` の3形態で共有し続ける。
3. 再生状態・キュー・再生回数などの**正本を Go コアだけに置く**。UI は購読して描画するだけにする。
4. 単一バイナリ・1 マシン 1 インスタンス・launchd ハンドオフという既存方針を維持する。

### 非目標

- Go コアの書き直し（言語変更も含む）。
- Windows 版のネイティブ化。必要になった時点で改めて判断する（§8）。
- 移行と同時に音声エンジンを AVAudioEngine に置き換えること。これは別の判断として扱う（§9）。
- 全機能を一度に移植すること。段階的に移す（§6）。

## 3. 全体構成

```
┌──────────────── UX-Music.app（Mac・単一プロセス） ────────────────┐
│  SwiftUI（UI 層・状態の正本を持たない）                             │
│   ├ CoreBridge.swift ── C ABI ──┐                                 │
│   ├ WKWebView（YouTube 公式 embed のみ）                           │
│   └ NSStatusItem / MPNowPlayingInfoCenter など OS 統合             │
│                                  ▼                                 │
│  libuxcore.a（Go, c-archive）                                      │
│   ├ server.App（既存・変更最小）                                   │
│   ├ server/app_native_adapter.go ★新規（Wails アダプタと同格）      │
│   ├ LAN API v1 / mDNS / Sync / Scanner                             │
│   └ pkg/audio（PortAudio・EQ・FFT・プロセスタップ）                  │
└────────────────────────────────────────────────────────────────────┘

Windows: 従来どおり main.go → wails.Run → server.App（app_wails_adapter.go）
--serve : Mac はネイティブアプリの実行ファイルを --serve 付きで起動（UI を作らない）
```

## 4. Go コアとの境界

### 4.1 接続方式: c-archive による同一プロセス内結合

Go を `go build -buildmode=c-archive` で `libuxcore.a` と C ヘッダにし、Xcode のビルドフェーズでリンクする。arm64 と x86_64 は `lipo` で universal にする。

採用理由:

- **単一バイナリの方針（`project_server_mode`）を崩さない。** 子プロセス方式はデーモン分離案に近く、ハンドオフも二重になる。
- 呼び出しがプロセス内で済むので、ループバック HTTP より遅延が小さく、失敗モードも少ない。

### 4.2 C ABI は「汎用 RPC ＋少数の型付き hot path」のハイブリッドにする

低頻度の呼び出しは関数ごとに C 関数を export せず、**Wails バインディングと同じ「メソッド名＋JSON 引数」の形**を汎用ディスパッチャで受ける。高頻度の呼び出しだけは、JSON を通さない型付きの関数として別に出す（§4.2.1）。UX-Inkwell の「高頻度は直接 FFI、低頻度は versioned JSON envelope」と同じ切り分けにする（§11）。

```c
// 同期呼び出し（戻り値は JSON。呼び出し側が uxm_free で解放）
char* uxm_call(const char* method, const char* args_json);
// 非同期呼び出し（重い処理用。完了はコールバックで通知）
void  uxm_call_async(uint64_t request_id, const char* method, const char* args_json);
// イベント購読（Go → Swift）。name は既存のイベント名をそのまま使う
void  uxm_set_event_handler(void (*handler)(const char* name, const char* data_json));
// ダイアログ要求（Go → Swift）。応答は uxm_dialog_result で返す
void  uxm_set_dialog_handler(void (*handler)(uint64_t id, const char* kind, const char* opts_json));
void  uxm_dialog_result(uint64_t id, const char* result_json);
void  uxm_free(char* p);
int   uxm_start(const char* mode /* "gui" | "headless" */);
void  uxm_shutdown(void);
```

- **ディスパッチャ**（`server/native_dispatch.go`・新規）は、Wails に Bind している `*App` の公開メソッド（現在 134 個）をリフレクションで引く。Wails と同じ JSON の直列化規則にそろえ、**Windows 版と Mac 版で呼べる API の表面を完全に一致させる。**
- **イベント**は既存の `a.emit(...)` に集約済み（Phase 0-1 で完了、34 種）。`app_native_adapter.go` の `wireNativeRuntime` で emitter を C コールバックに差し替えるだけで済む。
- **ダイアログ**は `DialogProvider` インタフェース化済み。ネイティブ版では Swift 側の `NSOpenPanel` を呼ぶ実装を差し込む。
- **WebView 破棄の API**（`windowUnloadWebViewFunc` など）はネイティブ版では no-op のまま。park は §5.4 のとおり不要になる。

#### 4.2.1 型付き hot path（JSON を通さない）

今の Web UI は、再生位置（`AudioGetPosition` / `AudioGetStatus`、`player.ts`）と FFT（`AudioGetFrequencyData`、`visualizer.ts`）を定期的に問い合わせている。ネイティブ版ではこれらを毎フレーム JSON で往復させない。

```c
// 呼び出し側が確保したバッファへ書き込む。確保と解放は発生しない
int  uxm_audio_snapshot(uxm_audio_snapshot_t* out);   // 位置・長さ・再生中・世代番号
int  uxm_audio_fft(float* out, int capacity);           // 戻り値は書き込んだビン数
```

- hot path として許可する関数は**この節に列挙したものだけ**にする。追加するときは、計測で JSON 経路がボトルネックだと示してから本節に追記する。
- 状態が変わったこと（曲の切り替え、停止など）はイベントで通知し、hot path は「今の値を読む」ためだけに使う。

#### 4.2.2 Swift 側は型付きクライアント 1 か所からだけ呼ぶ

- `uxm_call("メソッド名", ...)` を文字列で呼んでよいのは、`CoreClient.swift`（Codable の引数・戻り値型を持つ薄いラッパ）の中だけにする。View や ViewModel から直接呼ぶことは禁止する。
- `CoreClient` のメソッド一覧と、Go のディスパッチャが公開するメソッド一覧が一致していることを、テストで検証する（Go 側からメソッドのカタログを JSON で出力し、Swift のテストで突き合わせる）。
- **背景（UX-Inkwell の教訓）:** Inkwell は 4 関数の汎用コマンドバスを用意したが、UI は結局 73 個の個別 FFI 関数を直接呼ぶ形に育ち、バスは使われなかった（`ffi_research/notes/command-bus-surface.md`）。本計画では汎用ディスパッチャを**唯一の経路**にし（Wails 版もすでにこの形）、別に型付きの表面を育てない。例外は §4.2.1 の hot path だけにする。

### 4.5 C ABI の規約

UX-Inkwell の `src/cabi/`（`progress/c-abi-layer.md`）の規約を Go に置き換えて使う。

- **命名:** 接頭辞は `uxm_`。
- **パニック:** export するすべての関数を `defer recover()` で包み、パニックを下記のエラー形式に変換して返す。Go のパニックでプロセス全体を落とさない。
- **文字列:** UTF-8 の NUL 終端文字列を使う。Go が返した文字列は呼び出し側の所有物とし、`uxm_free` で解放する。Swift 側では `CoreClient` の中で `defer uxm_free` を必ず書く。
- **エラー:** LAN API v1 と同じ `{"error":{"code","message"}}` にそろえる。成功時は `{"result": ...}` とし、どちらにも `apiVersion` を付ける。
- **ハンドル:** 1 プロセス 1 インスタンスなので、`*App` はグローバルに 1 つだけ持つ。opaque ハンドルは出さない（Inkwell は Document ごとのハンドルが必要だったが、UX Music では不要）。
- **ヘッダ:** cgo が生成する `_cgo_export.h` を直接公開しない。手書きの `uxcore.h`（安定した ABI）を正本にし、生成ヘッダとの食い違いはビルド時のチェックで検出する。

### 4.3 型

- Swift 側の型は、可能な限り **LAN API v1（`/v1/remote/*`）の DTO と同じ形**にそろえる。そうすれば Mobile の `Models/`（`Song`・`Album`・`Playlist` など）をそのまま共有できる（§7）。
- JSON の形が LAN API とバインディングで食い違っている箇所は Phase 1 で一覧化し、どちらに寄せるかを個別に判断する。

### 4.4 スレッド

- イベントハンドラは Go のスレッドから呼ばれる。Swift 側では受け取ったらすぐにデータをコピーし、`MainActor` へ移してから UI 状態を更新する。コールバック内でブロックしたり、Go を呼び返したりすることは禁止する。
- `uxm_call` は UI スレッドから呼んでよいのは軽い処理（状態取得・再生制御）だけに限る。スキャン・同期・正規化などは `uxm_call_async` を使う。どちらを使うべきかの一覧は Phase 1 で作る。

## 5. 設計ルール（両 UI 共通）

### 5.1 状態の正本は Go コア

- 再生状態（現在の曲、位置、再生中かどうか）、キュー（`pkg/playqueue` に移行済み）、再生回数、設定の正本は Go に置く。
- UI は `queue-state-changed`・`audio-playback-finished` などのイベントと、`AudioGetStatus` などの取得系 API で**写像を持つだけ**にする。UI 側で「先に表示を進めて後から Go に伝える」ことはしない。
- これが §1.2 の「表示と音のずれ」への根本対策になる。

### 5.2 新しいロジックは Go に書く

- 判断を含む処理（並べ替え、シャッフル規則、状況別プレイリスト、スナップ判定の閾値など）は Go に実装し、テストも Go 側に置く。
- UI 固有の処理（アニメーション、レイアウト、入力操作）だけを各 UI に書く。
- 既存の TS 側ロジックは、ネイティブ UI で必要になった時点で Go に移す。そうすれば Windows 版も自動的にその恩恵を受ける。

### 5.3 Mac 固有の OS 統合は Swift に移す

| 機能 | 現状 | ネイティブ版 |
|---|---|---|
| メニューバー（トレイ） | `server/tray_darwin.m` | `NSStatusItem`（SwiftUI `MenuBarExtra`） |
| OS メディアコントロール | `server/os_media_darwin.m` | `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` |
| ウィンドウ表示状態 | `server/app_visibility_darwin.m` | `NSApplication` の通知 |

移すまでの間は既存の `.m` 実装をそのまま使ってよい。二重登録にならないよう、Phase 2 で1機能ずつ切り替える。

### 5.4 park（駐機）は廃止

WebView を破棄するのが目的だった仕組みなので、ネイティブ UI では不要になる。ウィンドウを閉じればビューが解放される。Go 側の `releaseMemoryAfterPark`（`FreeOSMemory` など）は「ウィンドウを閉じた時」に呼ぶ形で残す。

## 6. 移行フェーズ

### Phase 0: 検証スパイク（Go / No-Go 判定）

最小構成の SwiftUI Mac アプリに `libuxcore.a` をリンクし、次の項目を確かめる。コードは `native_bridge_research/tools/` に置き、本流には入れない。結果は `native_bridge_research/notes/` に記録する（`/research` の規律に従う。Inkwell の `ffi_research/` と同じ構成）。

| # | 検証項目 | 合格条件 |
|---|---|---|
| 1 | `uxm_call("Ping")` の往復 | 成功し、遅延は 1ms 未満 |
| 2 | イベント受信 | `queue-state-changed` を MainActor で受け取れる |
| 3 | PortAudio 再生・シーク・停止 | 既存の Wails 版と同じように動く |
| 4 | `--serve` ヘッドレス起動 | UI を作らずに LAN API と mDNS が動く |
| 5 | launchd ハンドオフ | GUI 起動時に常駐を止め、終了時に復帰する |
| 6 | WKWebView の YouTube embed とプロセスタップ | `AudioStartWebViewTap` が自分の WebKit ヘルパーを捕捉できる |
| 7 | メモリ | 起動直後の footprint が Wails 版（約 100MB＋WebKit）を下回る |
| 8 | ビルド | xcodegen の `preBuildScripts` で `go build -buildmode=c-archive` を実行し、Xcode からのクリーンビルドが通る。最初は **arm64 のみ**（Inkwell と同じ。universal 化は配布時に判断する） |
| 9 | hot path | `uxm_audio_snapshot` と `uxm_audio_fft` を 60Hz で呼んでもメインスレッドの負荷が問題にならない |

**不合格時:** #1〜#5 か #8 が不合格なら計画を中止し、Wails 版を改善する路線に戻る。#6 だけが不合格なら、YouTube を後回しにして続行するか判断する。

### Phase 1: 境界層（Go 側・TDD）

- `server/native_dispatch.go`: 汎用ディスパッチャ。テストを先に書く（メソッド解決、引数の JSON 変換、エラー形式、未知メソッド）。
- `server/app_native_adapter.go`: emitter と DialogProvider を差し替える。
- `cmd/uxcore/`: c-archive のエントリ（`//export` 関数群）。
- 同期・非同期呼び出しの区分と、LAN API とバインディングの JSON の差分を一覧化する。
- 状態の二重管理が残っている箇所（TS 側にしかない判断ロジック）を洗い出し、Go に移す候補リストを作る。

### Phase 2: 日常利用できる最小 UI（MVP）

**Tier 1（これがそろえば Mac では日常的にネイティブ版を使える）**

- ライブラリ（曲・アルバム・アーティスト・検索）
- プレイリスト（閲覧・再生・追加）
- 再生フッター、シーク、音量
- キュー
- Now Playing と同期歌詞（Mobile の `LyricsStageKit` / `LRCParser` を参考にする。スナップ判定は Go に寄せる）
- メニューバーと OS メディアコントロール（§5.3）

### Phase 3: 常用機能

**Tier 2**

- 設定（ライブラリパス、出力デバイス、EQ、正規化ゲイン）
- UX Sync（ペアリング QR、デバイス一覧、自動同期）
- YouTube（リンク追加、WKWebView での公式再生、タップ、LAN 中継）
- アートワーク変更、アルバム曲順の編集
- For You / 状況別プレイリスト

### Phase 4: 残りの機能の判断と Mac の Wails 版の退役

**Tier 3（使用頻度が低い。移植するか、Wails 版専用のまま残すか、廃止するかを個別に決める）**

- MTP 転送とブラウザ
- CD リップ（VocaDB メタデータを含む）
- 音量正規化ジョブ
- LRC エディタ
- ビジュアライザ
- クイズ
- サイドカーモード

Tier 3 の判断がすべて済んだ時点で、Mac 向けの Wails ビルドを配布対象から外す。

### 移行期間中の共存ルール

- ネイティブ版と Wails 版は同じ設定・ライブラリ・ポート 8765 を使う。Go コアがファイルの正本を持つので、どちらで起動しても同じデータが見える。
- 同時に起動しない（1 マシン 1 インスタンス）。後から起動した側は既存のハンドオフの仕組みに従う。
- Tier 3 の機能を使いたいときは Wails 版を起動する運用で許容する。

## 7. Swift コードの共有

### 7.1 プロジェクト構成（Inkwell 方式）

```
UX-Music/
├─ UX-Music.xcworkspace        ★新規: Mac・Mobile・共有パッケージを1つにまとめる
├─ UX-Music-Mac/               ★新規: project.yml（xcodegen）で生成し、.xcodeproj はコミットしない
├─ UX-Music-Mobile/            既存（手管理の pbxproj のまま。xcodegen には移行しない）
└─ UXMusicShared/              ★新規（Phase 4〜）: ローカル Swift Package
```

- **Mac プロジェクトは xcodegen で生成する。** pbxproj の差分がレビューできない問題と、並行作業での衝突（メモリ `parallel-agents-git-collision`）を避けられる。Mobile は既存のまま触らない。
- **ワークスペースを必ず使う。** ローカル Swift Package は一度に1つのワークスペースにしか属せない。2つの `.xcodeproj` を別々に開くと、後から開いた側がパッケージを失う（Inkwell で 2 回起き、CLI からは再現しないため原因の特定に時間がかかった。`progress/build-integration-xcode-cargo.md`）。
- **Xcode を開いたまま `xcodegen generate` しない。** これも Inkwell で実際に起きた事故。

### 7.2 共有の進め方

- まず Mobile のコードを**参照・コピー**して作り始め、共有パッケージの整備は後回しにする（Phase 2 の速度を優先する）。
- Phase 4 以降に、`UXMusicShared` へ `Models/` と UIKit に依存しない `Core/`（`LRCParser`、`LyricsStageKit`、`SongSearchFilter`、`LibrarySortOrder` など）を抜き出す。

### 7.3 「プロトコル＋純粋ロジック」と「実装」を分ける

Inkwell の `inkwell-shared` と同じ切り方をする（`progress/shared-swift-package.md`）。

- **共有パッケージに置くもの:** `*Serving` プロトコル（例: `LibraryServing`、`PlaybackServing`、`LyricsServing`）、その上で動く純粋なロジックと ViewModel、プラットフォームに依存しない View 部品。
- **各アプリに置くもの:** プロトコルの実装。
  - Mac: `CoreClient` 経由で Go コアを呼ぶ実装
  - iOS: `RemoteAPIClient`（LAN API v1）やローカル再生で実装
- 依存するサービスは init で注入し、static な既定値を型に持たせない（Inkwell の `EditorGroupsModel` で、共有パッケージへ移す妨げになった）。
- §4.3 で DTO を LAN API にそろえる方針と組み合わせると、Now Playing や歌詞表示の View を Mac と iPhone で共有できる余地が生まれる。

## 8. Wails 版（Windows）保守モードの基準

**Mac のネイティブ版が Tier 1 に達した時点で保守モードに入る。**

| 区分 | 扱い |
|---|---|
| 不具合修正 | 行う |
| Go コアの API 変更への追従 | 行う（コンパイルと既存テストが通る範囲） |
| Go コアに追加された新機能 | UI 側の変更が小さい（目安: TS で 100 行以内）ときだけ露出する |
| UI の新機能・デザイン刷新 | 行わない |
| TS のテスト | 維持する（壊れたら直す） |
| Wails フォーク | Windows に必要な範囲だけ追従する。darwin 専用の WebView 破棄 API は Mac 版の退役後に不要になる |

**Windows を本気でやる判断をしたとき:** 今の Wails 版を育て直すか、WinUI 3 などでネイティブ UI を作るかを選ぶ。どちらの場合も Go コアと §4 の境界はそのまま使える。

- ネイティブにする場合は、Inkwell の `inkwell-app-windows/` が前例になる（C# の `[LibraryImport]` P/Invoke、`SafeHandle`、UTF-8 文字列の所有権を管理するラッパ、xunit テストを macOS の dylib に対して実行する構成）。
- Go は `-buildmode=c-shared` で DLL を作り、同じ `uxm_*` ABI を C# から呼ぶ。
- Inkwell は swift-bridge と C ABI の**2つの FFI 表面を維持するコスト**を抱えている（`ffi_research/notes/recommendation.md`）。UX Music は最初から C ABI 1本なので、この二重保守は発生しない。

## 9. 未確定事項

- **音声エンジンの置き場所。** PortAudio のまま行くか、Mac だけ AVAudioEngine に寄せるか。本計画の範囲外で、Phase 2 以降に音切れや遅延が問題になったら `/research` で検証する。
- **非同期呼び出しのキャンセル方式。** `request_id` で取り消すか、Go の context を露出するか。Phase 1 で決める。
- **クラッシュ報告。** Go ランタイムのシグナル処理と Swift 側のクラッシュ収集が共存できるか。Phase 0 の追加確認項目にする。
- **Go ランタイム固有の制約。** Go のポインタを C 側に保持させられない（cgo のポインタ受け渡し規則）。コールバックを登録している間の Swift 側のコンテキストは `cgo.Handle` か整数 ID で受け渡す。`uxm_start` より前に呼ばれた場合や、二重に呼ばれた場合の挙動も Phase 1 のテストで固定する。
- **コード署名・公証（notarisation）。** c-archive にした PortAudio や libusb などのネイティブ依存（`progress/native-dylib-vendoring.md`）を .app に同梱する手順。
- **Tier 3 の各機能の去就。** Phase 4 で個別に決める。

## 10. 検討した代替案

| 案 | 不採用の理由 |
|---|---|
| Rust への全面リライト | §1.3 のとおり。今の問題を解決せず、テスト資産を失う |
| Go コアを Swift で書き直す | 2.6 万行とテストの書き直しが必要になる。Windows 版がコアを失う |
| Go を子プロセスにして、ループバック HTTP（LAN API）で UI と通信する | 単一バイナリの方針と衝突する。二重ハンドオフやプロセスの生死管理が増える。LAN API は外部端末向けの契約で、UI 専用の API（ダイアログ・EQ 描画用の FFT など）を載せると汚れる |
| Wails 版を改善し続ける | WebView 起因のコスト（§1.2）が構造的に残る。Mobile との二重実装も解消しない |
| Wails v3 などに移行する | Web UI であることは変わらず、根本的な動機を満たさない |
| gomobile bind で Objective-C フレームワークを生成する | 扱える型が限られ（スライスや構造体の制約）、134 メソッドを出すにはラッパ層が必要になる。イベントのコールバックや hot path の制御も効きにくい。Windows では使えない |

## 11. UX-Inkwell から得た知見のまとめ

Inkwell は Rust コア＋SwiftUI/AppKit（macOS）＋iPad＋WinUI 3（Windows）の構成を、実際に動かしている。本計画にそのまま使えるものと、避けるべき落とし穴を整理する。

| 知見 | Inkwell での根拠 | 本計画での扱い |
|---|---|---|
| コアを staticlib にして直接リンクし、xcodegen の `preBuildScripts` でビルドする | `progress/build-integration-xcode-cargo.md` | 採用（§6 Phase 0 #8） |
| 高頻度は直接 FFI、低頻度は versioned JSON envelope | `markdown/Architecture.md`「FFI 戦略」 | 採用（§4.2・§4.2.1） |
| 汎用コマンドバスを作っても、UI が個別関数を直接呼ぶように育つと使われなくなる | `ffi_research/notes/command-bus-surface.md` | ディスパッチャを唯一の経路にし、Swift 側の呼び出し口を1か所に限定する（§4.2.2） |
| C ABI の規約（接頭辞、panic 捕捉、文字列の所有権、error-out） | `progress/c-abi-layer.md` | Go 用に置き換えて採用（§4.5） |
| UI は OS API のアダプタに徹し、状態とコマンドの意味はコアに集める | `markdown/Architecture.md`「なぜこの分割か」 | §5.1・§5.2 と同じ方針。これで裏付けが取れた |
| WebKit は割に合わない領域だけの「逃げ場」にする | 同上（Markdown・HTML・メディアのプレビュー） | YouTube の embed だけに限定（§2 目標 1） |
| 共有 Swift Package は「プロトコル＋純粋ロジック」と「FFI 実装」で分ける | `progress/shared-swift-package.md` | 採用（§7.3） |
| ローカルパッケージは1ワークスペースにしか属せない。Xcode を開いたまま xcodegen しない | `progress/build-integration-xcode-cargo.md` | 運用ルールとして採用（§7.1） |
| FFI の選択は、まず `*_research/` で比較とスパイクを行ってから決める | `ffi_research/notes/` | Phase 0 を `native_bridge_research/` で行う（§6） |
| swift-bridge と C ABI を並走させると、二重保守が恒久的なコストになる | `ffi_research/notes/recommendation.md` | Go には swift-bridge 相当がないので、C ABI 1本にする（§8） |

**Inkwell と違う点:** Inkwell のコアは Rust で、Document など複数のハンドルと `&mut self` の型を扱う。UX Music のコアは Go で、App が1インスタンスだけあり、主な処理は長く動き続ける再生・同期・サーバーなので、FFI の表面はずっと単純になる。一方で Go 特有の事情が加わる。1プロセスに Go ランタイムは1つだけ、Go のポインタを C 側に渡せない、シグナル処理が共存する、の3点で、これらは Phase 0 で確認する（§9）。
