# 設定ページ再設計（モーダル→左ナビ付きフルページ）

## 決定事項
- `markdown/settings-redesign-proposal.md` の提案に沿い、旧「単一モーダルに14グループ縦一列＋OKボタンで一括保存」を廃止。
- `#settings-modal-overlay` を全画面オーバーレイに変更し、中身を `#settings-page`（ヘッダー＋`.settings-nav` 220px＋`.settings-content` 最大幅760px）に再構成。
- 保存契約を「コントロール変更のたびに即時保存」へ統一。`js/ui/settings/settings-store.ts` の `save(patch)` が `musicApi.saveSettings` を都度呼ぶ（バックエンド `SaveSettings` は shallow merge のため差分だけで安全）。OK ボタン・`electronAPI.send('save-settings', …)` の一括呼び出しは削除。
- ナビ切り替え・検索フィルタ・開閉・Esc・`open-settings` カスタムイベント（`detail.section`、`'audio'` は `'playback'` の別名）は `js/ui/settings/settings-page.ts` が担当。各セクションの中身は index.html に静的マークアップとして残し（EQ など既存の `getElementById` 依存コードを壊さないため）、`SectionDef.onShow` でセクション固有の再描画（EQ の `renderGraphicEQ()` など、冪等呼び出し前提）をフックする方式にした。

## セクション構成
一般 / 再生・オーディオ / ライブラリ / 外観 / YouTube / 連携 / AI機能(Beta) / 詳細。

移行網羅性は `js/ui/settings/settings-keys.ts`（旧 OK ハンドラが保存していたキー一覧）と `section-registry.test.ts` で機械的に検証している。

### 提案からの意図的な逸脱
- 「ダウンロード品質」は提案表では「再生・オーディオ」セクションに割り当てられていたが、YouTube再生モードのラジオと排他的に連動する disabled 制御（`updateQualityGroupState`）が密結合なため、実装は両方を YouTube セクションにまとめた。UX 上も自然と判断し記録のみ残す。

## デバイス可視性のインライン化
旧 `#devices-modal-overlay`（別モーダル＋OKボタン）を廃止し、「再生・オーディオ」セクション内の「表示するデバイスを管理...」ボタンでインライン展開する `#settings-audio-devices-list` に置き換えた。チェックボックスの変更ごとに `hiddenDeviceIds` を即時保存する（`init-settings.ts` の `toggleAudioDevicesList`）。

## UX Sync
提案の「妥当なら埋め込み、無理なら既存サブモーダルのまま」の判断で、既存の `#ux-sync-settings-modal-overlay`（タブ構造付き）はそのまま維持し、「連携」セクションの「UX Sync設定を開く」ボタンから起動する形を継続した。

## 既存 electronAPI/wails 呼び出しの再配線チェックリスト
- `musicApi.saveSettings` … 各コントロールの `change` イベントから直接（旧: OKボタン一括）
- `SetLyricsSyncModelConsent` … 歌詞同期モデル同意チェックボックスの `change` から即時
- `GetLyricsSyncResourceStatus` / `ClearLyricsSyncModelCache` … `populateSettingsFields` / クリアボタンから継続
- `GetPairingQRDataURL` / `GetPairingURL` … `refreshRemotePairingQR`（不変）
- `DiscoverSyncDevices` / `ListSyncDevices` / `startSyncPairing` / `confirmSyncPairing` / `PullSyncLibraryAssets` / `PushSyncLibraryAssets` … UX Sync サブモーダル内のロジックを変更なしで維持
- `AnalyseLibraryAudioEmbeddings` 等の AI 音声解析 API … `initAiEmbedSettings()` の配線は不変（DOM は常時存在するため、セクション非表示中でも安全に動作）

## 検証結果
- `npm test`: 43 ファイル / 430 テスト全通過（新規: `settings-store.test.ts`, `settings-page.test.ts`, `section-registry.test.ts`）
- `npx tsc --noEmit`: エラーなし
- `npm run build`: 成功（既存の dynamic-import chunk 警告のみ、本変更起因ではない）
- `make build` → `build/bin/UX-Music.app` 起動確認: 初期ウィンドウは正常表示（曲一覧・サイドバー・再生バー）。`cliclick`/`osascript` によるボタン合成クリックは Accessibility 権限がなく失敗したため、設定ページを開いた状態のスクリーンショットは取得できていない（正直に申告）。

## 残課題・今後の検討
- 「詳細」セクションの pprof 診断リンクは説明文のみで、実際のエンドポイント表示・トグルは未実装（既存の pprof 起動は Go 側の別経路）。

## 追補（67b）: 見た目確認と行レイアウトの実装
上記「残課題」にあった実機見た目確認をヘッドレス Chrome で実施した結果、CSS が当初から欠落しており致命的に崩れていたことが判明。

### 根本原因
1. `.settings-button { width: 100%; margin-top: 10px }`（旧・単一モーダル用のレガシールール）が `#settings-close-btn` にもそのまま適用され、ヘッダーが横幅いっぱいのボタンに占領されて `<h2>設定</h2>` が潰れていた。
2. `.checkbox-group`（`label > input[checkbox] + div > strong + small` のマークアップ）に対応する CSS が一切存在せず、素の checkbox とインライン文章がそのまま流れて表示されていた。`.radio-group` 側は既にスタイルがあり無事だった。

### 修正内容（`src/renderer/styles/components.css`）
- `.settings-button` から `width: 100%; margin-top: 10px;` を削除し `width: auto` に変更。`#settings-page .setting-item > .settings-button` にのみ `margin-top: 10px` を限定付与（説明文の下に単独で置かれるボタン用。`.ux-sync-transfer-actions` 等のフレックス行内の兄弟ボタンは対象外にして横並びを維持）。
- `#settings-page .checkbox-group label` / `.radio-group label` を `display: grid; grid-template-columns: 1fr auto` の行として新設。タイトル(`strong`)+説明(`small`)のブロックを `order: 1`、コントロールを `order: 2` にして常に右寄せ（マークアップの DOM 順は変更せず、CSS の `order` だけで並べ替え、既存 JS の `querySelector` 依存を壊さない）。
- checkbox は `appearance: none` + `::before` で 38×22px のピル型トグルスイッチとして描画（`input` 要素自体は維持するため JS 側の `change` リスナーは無改修で動作）。
- `.setting-child-item`（Analysed Queue のスコア有効期間スライダー等）は左ボーダー付きインデント行に変更。旧・重複定義（同名セレクタが離れた場所に2箇所存在し後勝ちで意図しない上書きが起きていた）を1箇所に統合。
- `#graphic-eq-container` に `min-height: 320px` を追加。

### 開発用クエリフラグ（見た目確認専用）
- `?settings=<sectionId>` … `settings-page.ts` の `mount()` 末尾で `location.search` を読み、該当セクションを開いた状態で起動する（`open-settings` イベントを使わない静的アクセス）。
- `&theme=mc` … MusicCenter テーマ (`body.mc-theme`) を強制する。**注意**: `init-settings.ts` の `initSettings()` は起動時のテーマ復元を `loadRendererSettings().then(...)` の非同期コールバック内で行うため、`theme=mc` の適用もこの `.then()` 内（`applyUiTheme` 呼び出しの直後）に置く必要がある。同期的な `settings-page.ts` 側で処理すると、後から解決する非同期のテーマ復元処理に上書きされて無効化される（実際にこの順序バグを一度踏んでスクリーンショットで確認済み）。
- どちらも本番動作には影響しない（パラメータが無ければ何もしない、`try/catch` で `location` 不使用環境=テストも安全）。

### 見た目検証
Vite dev server (`localhost:5179`) + ヘッドレス Chrome (`--headless=new --screenshot`) で以下をスクリーンショット確認済み（`/private/tmp/.../scratchpad/settings-*.png`、セッション終了後は消滅するため再検証時は同じ手順で再取得）:
- `?settings=general` `?settings=playback` `?settings=library` `?settings=appearance` `?settings=youtube` `?settings=integration` `?settings=ai` `?settings=advanced` … いずれもヘッダー・行の整列・トグルスイッチが正常。
- `?settings=general&theme=mc` … MusicCenter テーマでも角丸が四角になるだけで崩れなし。

### 検証結果（67b）
- `npm test`: 43 ファイル / 430 テスト全通過
- `npx tsc --noEmit`: エラーなし
- `npm run build`: 成功（既存の dynamic-import chunk 警告のみ）
