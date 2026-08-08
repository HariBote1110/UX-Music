# デスクトップ版 YouTube 機能のゲート外し（既定で公式再生を有効化）

## Decision
- `settings.enableYouTube` による YouTube 機能全体のゲート（ライブラリ管理ポップアップの「YouTubeリンクを追加」「YouTubeプレイリストを追加」ボタン、設定モーダルの再生モード欄一式）を撤廃。新規インストール直後から YouTube 追加・公式再生（embed）が使える。
- 既定の再生モードを `download` から `embed`（公式再生・IFrame プレイヤー、127.0.0.1 ループバック）に変更。
  - `src/renderer/js/utils/init-settings.ts`: 設定モーダルを開いたときに選択するラジオの既定値 `settings.youtubePlaybackMode || 'embed'`。
  - `server/app_youtube.go`: `AddYouTubeLink` が読む既定値を関数 `resolveYoutubePlaybackMode` に切り出し、フォールバックを `'embed'` に変更。
- ダウンロードモード／ストリーミングモード（非公式）の**選択肢だけ**を隠す形に縮小。従来の `enableYouTube` ゲート機構（`data-feature` 属性 + hidden クラス + debug コマンド + 同意モーダル）をそのまま流用し、対象を `data-feature="youtube-advanced"` に絞って再利用。設定キーも `enableYoutubeAdvancedModes` にリネーム（未リリースのため後方互換は考慮せず）。
  - 対象要素: 設定モーダルの `download`/`stream` ラジオ `<label>` と `#youtube-quality-group`。
  - `embed` ラジオと YouTube 追加ボタン群は常時表示（`data-feature` 属性を除去）。
  - 解放トリガーは従来どおり「ライブラリを管理」ボタン7連打、または `uxDebug.enableYoutubeAdvancedModes()`。
  - 初期ロード時の反映は `src/renderer/renderer.ts` の `settings-loaded` ハンドラ（旧: `if (settings.enableYouTube) { …[data-feature="youtube"]… }` → 新: `enableYoutubeAdvancedModes` / `youtube-advanced` に更新）。この初期ロード時反映ロジックはコード探索で見落としやすい場所なので明記しておく。
- UI 文言の整理: 同意モーダルの文言を「YouTube機能の有効化」から「YouTube追加モードの有効化」に変更し、公式再生は既定で使える旨が伝わるようにした。「非公式」という語自体はストリーミングモードの説明文に残しているが、これはユーザーに実態を正しく伝えるための意図的な表記であり、内部用語の漏洩ではないため据え置き。

## Alternatives considered
- `enableYouTube` の設定キーをそのまま残し値の意味だけ変える案 → 未リリース機能で後方互換不要なため、キー名も新しい意味（advanced modes）に合わせてリネームする方が紛らわしくない。

## Constraints / Gotchas
- YouTube 関連の初期表示ロジックは `src/renderer/renderer.ts` の `settings-loaded` ハンドラと `src/renderer/js/utils/debug-commands.ts` の `revealYoutubeAdvancedModesUI` の**2箇所**に分散している。片方だけ直すとリロード後に表示状態が食い違うので要注意。
- `server/app_youtube.go` の `resolveYoutubePlaybackMode` は `usesStreamingRegistration` (`stream`/`embed` を判定) と組み合わせて使われる。デフォルトを `embed` にしたことで、未設定状態でも `AddYouTubeLink` はダウンロードせず type:"youtube" のストリーミング登録経路に入る。
