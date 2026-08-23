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
- 設定ページを開いた実機での見た目確認（Accessibility 権限を有効化した上での再検証）が未実施。
- 「詳細」セクションの pprof 診断リンクは説明文のみで、実際のエンドポイント表示・トグルは未実装（既存の pprof 起動は Go 側の別経路）。
