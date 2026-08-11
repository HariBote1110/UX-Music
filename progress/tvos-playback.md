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
