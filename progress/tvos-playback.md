# tvOS 閲覧UI・擬似ストリーミング再生（Phase 1-3/1-4）

## Decision

- **棚構成**: アルバム（`Album.fromSongs` を iOS と共用）・プレイリスト（`/v1/remote/playlists`）の
  2 棚のみ実装。文字検索は主導線にせず、`.buttonStyle(.card)` による標準 tvOS フォーカス演出
  （カードリフト）を採用（`TVBrowseView.swift`）。
- **アートワーク**: `RemoteAPIClient.artworkURL(artworkId:)`（`?token=` 済み URL）を
  `AsyncImage` にそのまま渡す非同期ロード＋プレースホルダー（`TVArtworkImage`）。iOS 側の
  アートワークローダーはディスクキャッシュと密結合で共有に適さないため、TV 専用の薄い実装とした。
- **再生パイプライン**: 新規コードパスを増やさず、既存 `MusicPlayerService`（EQ + LUFS、
  iOS/watchOS と共有）をそのまま利用。`MusicPlayerService` は `Song.path`（ローカルファイルパス）
  を読むだけなので、TV 側の役割は「再生前にそのパスへ実ファイルを用意すること」だけに限定した
  （`TVPlaybackController`）。ラウドネス正規化も `MusicPlayerService.loudnessMap` に
  `/v1/remote/loudness` の値を渡すだけで既存のゲイン計算（`targetLUFS - songLUFS` →
  `pow(10, gainDb/20)`）がそのまま適用される。TV 側での再実装はしていない。
- **先読み**: `TVPrefetchPlanner.songIdsToPrefetch` は現在曲＋キュー先頭 2 曲（既定値）を
  純粋関数として返す。ネットワーク／ディスクを一切触らないため XCTest で直接検証できる。
- **キャッシュ（`TVPlaybackCacheStore` / `TVPlaybackCachePlan`）**:
  - 置き場所は `Caches/TVPlaybackCache/`（OS がパージし得る前提）。上限 2GB（既定値）。
  - 削除順序（LRU）の意思決定は `TVPlaybackCachePlan.entriesToEvict` に切り出した純粋関数。
    「最終アクセスが古い順に、保護対象（現在再生中・先読み対象）を除いて、必要バイト数を
    確保できるまで削除する」というルールを、ディスク I/O なしで XCTest 検証している。
  - 実ファイル I/O・LRU 実行・エビクションは `TVPlaybackCacheStore`（actor）が担当。
  - UI 上に「ダウンロード済み」概念は一切出していない（棚・再生画面ともにキャッシュ状態は
    表示しない）。
- **再生中パージ対策**: `TVPlaybackCacheStore.pinCurrentlyPlaying(songId:)` で現在再生中ファイルの
  `FileHandle` を開いたまま保持する。APFS/HFS+ では unlink 済みでも fd を閉じるまでデータが
  生き続けるため、エビクションが誤って現在再生中ファイルを削除しても再生自体は継続する
  （**保証ではなく緩和策**である点を明記: パスから再オープンが必要な操作——例えばコールドリランチ
  後の再開——はこの保護の対象外）。加えて `entriesToEvict` の `protectedSongIds` 引数で
  現在再生中・先読み対象の songId は最初からエビクション候補から除外している（二重の保護）。
- **エラー処理**: Host 不達時は `TVPlaybackController.connectionState = .unreachable(message:)`。
  オフラインモードは実装しない（計画どおり）。

## Alternatives considered

- **AVPlayer による直接ストリーミング**: 採用せず。EQ/LUFS を全端末で一貫させるという既存方針
  （`markdown/appletv-servermode-plan.md` の明文化事項 5）に反するため。
- **TV 専用のラウドネスゲイン再実装**: 不要と判断。`MusicPlayerService.applyLoudnessGain` は
  private だが `loudnessMap` 経由で同じロジックが自動適用されるため、re-export や複製をしない
  方が保守コストが低い。
- **iOS のアートワークキャッシュを共有ターゲット化**: 見送り。iOS 側はオンデバイス永続キャッシュ
  前提の設計で、tvOS の「OS がいつでもパージしてよい」方針と噛み合わないため、TV ローカルの
  薄い実装に留めた。

## Constraints / Gotchas

- **最近再生棚は未実装**: `/v1/remote/*` に再生履歴を返すエンドポイントが存在しない
  （`fetchSongs`・`fetchDesktopPlaylists`・`fetchLoudness`・`fetchLyrics`・`fetchState` のみ）。
  計画書どおり「データ源がなければ棚ごと出さない」を採用。将来 `/v1/remote/history` 等が
  追加された場合、`TVBrowseModel` に棚を足す形で拡張できる。
- **お気に入り棚も未実装**: Mobile 側にお気に入り機能自体が実装されていないため、計画書の
  「Mobile 側実装状況に追従」ルールに従い省略。
- **`TVPlaybackCacheStore.estimatedIncomingBytes`**: ダウンロード開始前は実ファイルサイズが
  不明なため、64MB の固定見積りでエビクション要否を判定している。ダウンロード完了後の実サイズは
  `currentEntries()` がディスクから都度読み直すため、次回のエビクション判定には反映される
  （見積り誤差は次サイクルで自己修正される設計）。
- **`pinCurrentlyPlaying` は `FileHandle` を開くだけ**で `AVAudioFile` 自体の生存は保証しない。
  `MusicPlayerService` は `AVAudioFile(forReading:)` を都度開くため、再生開始後にファイルが
  物理的に消えると次の `seek`/再スケジュール時に失敗し得る。Phase 1 では発生頻度が低いと判断し
  実装を簡素化したが、実機検証で問題が出た場合は `TVPlaybackCacheStore` 側でエビクション対象から
  「再生中」を最優先で除外する仕組みを強化する。

## 追記（2026-08-13）: 実機報告「再生開始が遅すぎる」の調査と修正

### 真因

`TVPlaybackController.play(_:queue:)` が **現在曲＋先読み対象（既定で次の2曲、計3曲）の
フルファイルダウンロードを全部 `await` し終えてから** `player.play(...)` を呼んでいた
（`for id in idsToPrefetch { ... try await cache.ensureCached(...) ... }`）。先読みは本来
「次の曲のための事前準備」であり、現在再生中の音声には無関係のはずなのに、実装上は
タップ→初回音声のクリティカルパスに丸ごと乗っていた。加えて `client.fetchLoudness()`
（LAN API 呼び出し）も現在曲のダウンロードより前に直列で `await` していた。ライブラリの
約88%が FLAC（実測: 1曲あたり 30〜60MB）であるため、この直列化は「現在曲1曲分」の
3倍近い待ち時間をユーザーに強いていた。

ダウンロード経路自体（`RemoteAPIClient.downloadFile` は既定で `source=original` を付け、
デスクトップ側の生ファイルをそのまま返す）はボトルネックではないことを実測で確認済み
（同一Mac上のループバックで 45.9MB の実FLACが 54ms、931曲のライブラリを持つ実ホストに対して）。
一方 `source=original` を付けずに叩くと（トランスコード経路）5.5MBのAAC変換に2.6秒かかる
ことも判明したが、これは既存コードが最初から `preferOriginalAudio: true` を既定にしていたため
実害はなかった（誤って `source=original` を外す変更を将来しないよう、ここに実測値を残す）。

### 修正

`TVPlaybackController.play`:
- **現在曲のダウンロードのみ** を `await`（`cache.ensureCached(songId: song.id, ...)`）。
- ラウドネス取得は `async let loudnessTask = client.fetchLoudness()` で現在曲ダウンロードと
  並行実行し、`player.play` 直前に `await`（同じレイテンシ予算内に収まるので、現在曲より
  ダウンロードが速いラウドネスAPIがクリティカルパスを伸ばすことはない）。
- **先読み対象の残り（現在曲を除いた分）は `Task.detached(priority: .utility)` で
  fire-and-forget** にし、`player.play` 呼び出し・`connectionState = .ready` の後に発火する
  ようにした。エラーは無視（`try?`）——先読み失敗は「次の曲の再生開始が遅くなる」という
  縮退にしかならず、現在の再生を止める理由にはならない。
- `DEBUG` ビルドで `[TVPlay] tap→firstAudio: <ms>` を計測ログ出力するようにした
  （`DispatchTime` ベース、`play()` 呼び出し開始から `player.play` 完了までを計測）。

### 検証（実測値）

Apple TV シミュレータ（`UXTV_PREVIEW=livenowplaying` — 新設の DEBUG 専用ハーネス、
`UXMusicTVApp.swift` の `TVLiveNowPlayingHarness`）から、稼働中のライブホスト
（`http://127.0.0.1:8765`、実ライブラリ931曲、`masterVolume = 0` でミュート）に対し、
現在曲＋次2曲（既定の `prefetchCount`）を含む実キューで `TVPlaybackController.play` を実行し、
`[TVPlay]` ログをキャッシュクリア済みの状態から測定（同一Mac上のループバック接続、
3曲とも実FLAC・約束キャッシュなしの初回ダウンロード）:

- **修正前**（3曲を直列 `await` するアルゴリズムに `[TVPlay]` ログのみ追加した一時ビルドで測定）:
  **471ms**
- **修正後**（本修正）: **309ms**（約 34% 短縮）

ループバック接続のため絶対値は実際のWi-Fi環境より大幅に小さいが、短縮の構造は
「現在曲1曲分の待ちから、先読み分（2曲分）の待ちを完全に除去した」ことによるもので、
実際のWi-Fi環境（1曲あたりのダウンロードが数百ms〜数秒かかる想定）では短縮の絶対時間が
このループバック計測より大きく開くと見込まれる（先読み2曲分のダウンロード時間がまるごと
クリティカルパスから外れるため）。

### 次の一手（今回は実装しない）

大容量FLACのフルファイルダウンロード自体がWi-Fi実測でボトルネックになる場合、次のレバーは
チェイス再生（部分ファイル受信しながら再生開始する擬似ストリーミング）——計画書
（`markdown/appletv-servermode-plan.md`）で既に触れられている方向性。今回はタップ→初回音声の
「順序・並行性」の修正に留め、チェイス再生の実装には着手していない。
