# サイドカーモード（Mac→iOSデバイスへの全画面Now Playing表示プッシュ）

## Decision
- 再生はMacに残したまま、ペア済みiPhone/iPadへフルスクリーン相当のNow Playing表示（ジャケット＋歌詞＋進行）を「Mac側の操作だけで」映す。MagSafe横置きiPhoneをサイドカー的ディスプレイにするのが狙い。
- **Mac起点・ポーリング搬送**: iOSはバックグラウンドから画面を起こせないため、「Mobileアプリがフォアグラウンドであること」を前提に、既存 `GET /v1/remote/state` へ追加した `sidecar: {active: bool}` を指示チャネルにした。新しい通信路（WebSocket/SSE/アウトバウンドpush）は追加していない。
- デバイス識別: `deviceAuthMiddleware` がトークン照合時に破棄していた deviceID を request context へ付与するよう変更（`deviceTokenIsValid` が `(deviceID, ok)` を返す）。これに乗せて in-memory の last-seen 記録（`*App` 上、10秒以内=online）を実装。
- Desktop UI 入口はフルスクリーン動線に同居: ジャケット右クリックメニューと `#now-playing-fullscreen-btn` の長押し(約500ms)から「サイドカーに表示」サブメニュー（`ListPairedRemoteDevices` で毎回取得、offline はグレーアウト、現在ターゲットは ✓ 表示・再クリックで解除）。通常クリックは従来通りローカルフルスクリーン。
- iOS側は `AppModel` にアプリレベルのフォアグラウンドポーラー（scenePhase active 中、2秒間隔）を新設。どのタブにいても directive を受けて `fullScreenCover` で `SidecarScreen` を提示/解除。表示中は `isIdleTimerDisabled = true`。進行バーは position+timestamp+playing からの純関数補間で2秒ポーリングでも滑らかに動く。
- ジャケット/歌詞のID解決のため state 応答へ `songId`/`artworkId` を追加（renderer が `AudioSetNowPlayingMetadata` 経由で供給）。無い場合は既存 RemoteControlScreen 同様のタイトル曖昧一致へフォールバック。
- ペアリング redeem 時の `DisplayName`（リクエストに元々存在したが未使用だった）を新設定キー `remoteDeviceNames` に永続化し、デバイス一覧の表示名に使用。
- iOS側ローカル解除（×ボタン）は「directive が一度 false に戻るまで再提示を抑制」する純関数ポリシー（`SidecarPresentationPolicy`）で実装。

- 追補（フィードバック対応）: (1) デバイス名は再ペアリング不要で直すため、クライアントが認証済みLANリクエスト全てに `X-Device-Name` ヘッダで名乗り、サーバーは値が変わった時だけ `remoteDeviceNames` へ保存（毎ポーリング書込み回避、64文字上限、CORS許可リストへ追加）。非ASCII名はURLSessionが素通しすることを実測確認し無加工で送信。 (2) サイドカー表示中は横画面固定: `AppDelegate` の `supportedInterfaceOrientationsFor` が静的 `SidecarOrientationLock` を参照し、表示時に `.landscape`＋`requestGeometryUpdate`、解除で `.all` に復帰（判定は純関数 `SidecarOrientationPolicy`）。 (3) ビジュアル刷新: 角丸+影+微ボーダーのジャケット、タイポ階層、歌詞アクティブ行強調と距離減衰、5秒無操作で操作UIフェード（`SidecarChromeVisibilityPolicy`、純関数）。

## Alternatives considered
- **Mobile起点の自動昇格（横向き+給電+再生中で自動遷移）**: StandBy的で魅力はあるが、Mac側操作だけで完結する動線を本線にしたため第2段のオプション扱いに格下げ（未実装）。
- **SSE/WebSocket化**: ボタン押下→表示まで最大2秒の遅延はポーリングで許容と判断。体感が悪ければ後日push化。
- **Macから端末へのアウトバウンドHTTP push**: LAN APIはインバウンド専用であり、iOS側の待受サーバー追加はコストと電池面で不利。ポーリング便乗が最小変更。

## Constraints / Gotchas
- last-seen は in-memory のためプロセス再起動でリセット（全デバイスが一時的に「未接続」表示になる）。
- `artworkId` は `song.artwork.full` がハッシュ名ファイルのときのみ導出される（renderer 側 `deriveArtworkIdFromArtworkFilename` は Go の `hashStemFromArtworkFilename` を鏡写し）。それ以外は空文字→曖昧一致フォールバック。
- Mobile の `RemoteControlScreen` のポーリングとアプリレベルポーラーは併走しうる（どちらも読み取りGETのみで無害）。
- サイドカー画面の遠隔操作コントロール（タップで一時停止等）は未実装。`RemoteAPIClient.sendCommand` が `model.withFailover` から届くため後付け可能。
- 既存の未解決事項: `Localizable.xcstrings` に `tv.relay.error.unknown` の訳が欠けており、カタログ完全性テストが1件failする（本件と無関係・先行作業由来）。

## 追補: サイドカーデバイス選択メニューが無関係な操作で消える不具合（Beta-55b）
- 症状: Desktop側の「サイドカーに表示」コンテキストメニュー（ジャケット右クリック／フルスクリーンボタン長押し）が「わけわからないところで」一瞬で消える、という報告。
- 調査したが原因ではなかった経路: (1) 非同期ギャップ — `openSidecarMenu`（`js/ui/now-playing.ts`）は `getSidecarTargetDevice`/`listPairedRemoteDevices` を await してから `showContextMenu` を呼ぶため、長押し release の pointerup/click がメニュー表示より先に発火するが、`showContextMenu`（`js/ui/utils.ts`）は dismiss リスナー登録自体を `requestAnimationFrame` で1フレーム遅延させており、開いた直後の残存イベントでは閉じない設計に既になっていた。(2) サブメニューの `mouseleave` 即時収納 — サブメニューは親 `menuItem` の DOM 子要素として追加されており、親→子への移動では `mouseleave` が発火しないため対角移動で消えるケースは再現しなかった。
- 真因: `showContextMenu` が `document` に `capture:true` の `scroll` リスナーをグローバル登録しており、メニューと無関係などの要素（曲一覧・サイドバー等）をスクロールしただけでも `removeContextMenu()` が呼ばれていた。メニュー要素自体は CSS で `position: fixed`（`styles/components.css` `.context-menu`）のためビューポート内で位置が動かず、本来スクロール追従は不要。曲一覧などの他の呼び出し元では「一覧の文脈が変わったら閉じる」という設計として妥当だが、フルスクリーン長押しで開くサイドカーメニューには無関係で、ユーザー体感としては「関係ない場所を触っただけで消える」不具合になっていた。
- 修正: `showContextMenu(x, y, items, options?)` に `ShowContextMenuOptions.closeOnScroll`（既定 `true`）を追加し、他の呼び出し元（曲リスト・列設定・MTPブラウザ・歌詞メニュー等）は無変更のまま、サイドカーメニューの呼び出し（`openSidecarMenu`）だけ `{ closeOnScroll: false }` を指定してスクロールでは閉じないようにした。Escape・外側クリック・別要素への右クリックでの dismiss は維持。
- テスト: `js/ui/context-menu-dismiss.test.ts`（jsdom）でデフォルト挙動（無関係要素のスクロールで閉じる）・`closeOnScroll:false` 時に閉じないこと・`closeOnScroll:false` でも Escape では閉じることを検証。
- 手動確認手順（実機）: Mac版でペア済みデバイスがある状態で、①ジャケット右クリック、②フルスクリーンボタンを約500ms長押し、のそれぞれでメニューを開き、開いたまま曲一覧やサイドバーをスクロールしてもメニューが消えないこと、Escapeキーやメニュー外クリックでは従来通り閉じることを確認する。あわせて曲一覧右クリックメニューでは従来通りスクロールで閉じることも確認する（`closeOnScroll` 既定値の回帰確認）。
