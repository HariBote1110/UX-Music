# TV: スキップ・自動再生の無音問題とlocalFileResolver

## 決定
- TVではキュー内の曲の `Song.path` がサーバ側パスのままで、初回タップ曲だけ `TVPlaybackController.play` がキャッシュファイルのローカルパスに書き換えていた。`next()`/`previous()`/`playQueueItem`/`advanceAfterEnd` は `MusicPlayerService` 内で完結するため、`loadAndPlay` の `fileExists` ガードで黙って離脱し「曲名だけ変わって音はそのまま／終了後停止」になっていた。
- `MusicPlayerService.localFileResolver: ((Song) async -> Song?)?` を追加。`loadAndPlay` がファイル不在を検知した時だけ呼び、解決後は `currentSong`/`queue` のパスも書き戻す（シークやルート変更の再スケジュールが再読するため）。解決の `await` 後にも `PlaybackGenerationGuard` を再チェックし、追い越された呼び出しは無変更で離脱。
- TV側は init で resolver を設定: `ensureCached`（プリフェッチ済みなら即時）→ `pinCurrentlyPlaying` → パス書き換え。iOS/watchOSは resolver 未設定で挙動不変。
- ラウドネスは `player.loudnessMap` が全曲分を保持し `loadAndPlay` が曲毎に適用するため追加対応不要。

## 却下した代替案
- TVのUI/リモート経路を `TVPlaybackController` 経由に付け替える案 → キューの真実が2箇所に分裂し、`advanceAfterEnd`（Service内部の自然終了）をフックできず不完全。単一チョークポイント（loadAndPlay）での解決を選択。

## 制約・注意点
- 未キャッシュ曲へスキップした場合はフル取得完了まで再生開始が待たされる（ストリーム開始への切替は未実装、プリフェッチで通常は即時）。resolver からプリフェッチ計画は起動しない（クロージャがSongしか受けないため。必要になったら要検討）。
- `xcodebuild -target` はリポジトリ内に `build/` を生成する。`.gitignore` 済み。
