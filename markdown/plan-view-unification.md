# 計画書：ビュー表示方式の統一（案2：mainContent 書き換え方式への統一）

## 概要

現在、デスクトップアプリのビュー表示には以下の **2系統** が混在している。

| 方式 | 対象ビュー | 仕組み |
|------|-----------|--------|
| **A: mainContent 書き換え方式** | 全曲・アルバム・アーティスト・For You・プレイリスト（詳細含む） | `mainContent.innerHTML` を動的に書き換え |
| **B: 独立 div オーバーレイ方式** | ノーマライズ・歌詞編集（LRC）・クイズ・MTP ブラウザ・CD リッパー | `mainContent` を hidden にして専用 div を表示 |

本計画は、すべてのビューを **方式 A（mainContent 書き換え方式）** に統一することで、ナビゲーション・ロジックを単純化し、コードの一貫性を高めることを目的とする。

---

## 目標状態

```
showView(viewId)
  ↓
mainContent は常に表示
mainContent.innerHTML を新しいビューの HTML で書き換え
  ↓
各ビューの render 関数が mainContent に描画する
```

- `mainContent` が hidden になるケースを **ゼロ** にする。
- `component-loader.js` による外部 HTML ファイルの非同期ロードを廃止する。
- `showView()` 内の `isSpecialView` 分岐を削除する。
- 各特殊ビューの「初期化関数」を「render 関数」として再定義する。

---

## 現状の問題点

### 1. `showView()` の二重ロジック

`src/renderer/js/core/navigation.js` の `showView()` 関数には、通常ビューと特殊ビューで処理が分岐している。

```js
// 現状（概念コード）
function showView(viewId) {
    const specialViews = ['normalize-view', 'lrc-editor-view', 'quiz-view', ...];
    if (specialViews.includes(viewId)) {
        mainContent.classList.add('hidden');           // メインを隠す
        document.getElementById(viewId).classList.remove('hidden'); // 特殊 div を表示
    } else {
        mainContent.classList.remove('hidden');
        mainContent.innerHTML = renderXxxView();       // 通常レンダリング
    }
}
```

この分岐が存在するため、ビューを追加するたびに `showView()` を修正する必要がある。

### 2. `component-loader.js` による外部 HTML の事前ロード

アプリ起動時に `lrc-editor.html`・`normalize.html` などを fetch して DOM に注入している。これにより：

- 起動時に不要な HTML がすべてロードされる（初期表示に不要なリソース）
- HTML テンプレートと JS の依存関係が暗黙的になる
- TypeScript 移行時に型付けが困難

### 3. 初期化関数とレンダリングの混在

特殊ビューは `initNormalizeView()` のような「初期化関数」として実装されており、呼び出しタイミングが `renderer.js` の起動シーケンスに依存している。通常ビューの `renderTrackView()` と設計思想が異なる。

---

## 変更対象ファイル一覧

| ファイル | 変更種別 | 変更内容の概要 |
|---------|---------|-------------|
| `src/renderer/js/core/navigation.js` | 修正 | `isSpecialView` 分岐を削除、全ビューを統一フローで処理 |
| `src/renderer/js/component-loader.js` | 削除（または空化） | 外部 HTML の事前ロード処理を削除 |
| `src/renderer/renderer.js` | 修正 | `loadAllComponents()` 呼び出しを削除、特殊ビューの `init` 呼び出しを削除 |
| `src/renderer/js/features/normalize-view.js` | 修正 | `initNormalizeView()` → `renderNormalizeView(container)` に再設計 |
| `src/renderer/js/features/lrc-editor.js` | 修正 | `initLrcEditor()` → `renderLrcEditor(container, track)` に再設計 |
| `src/renderer/js/features/quiz.js` | 修正 | `initQuiz()` → `renderQuizView(container)` に再設計 |
| `src/renderer/js/features/mtp-browser.js` | 修正 | `initMtpBrowser()` → `renderMtpBrowserView(container)` に再設計 |
| `src/renderer/js/features/cd-ripper.js` | 修正 | `startCDRipView()` → `renderCdRipView(container)` に再設計 |
| `src/renderer/components/normalize.html` | 削除 | JS による HTML 生成に移行 |
| `src/renderer/components/lrc-editor.html` | 削除 | JS による HTML 生成に移行 |
| `src/renderer/components/quiz.html` | 削除 | JS による HTML 生成に移行 |
| `src/renderer/components/mtp-transfer.html` | 削除 | JS による HTML 生成に移行 |
| `src/renderer/components/cd-ripper.html` | 削除 | JS による HTML 生成に移行 |
| `src/renderer/index.html` | 修正 | 特殊ビュー用の `<div id="xxx-view">` を削除 |
| `src/renderer/styles/layout.css` | 修正 | `.view-container` のオーバーレイ前提スタイルを削除 |
| `src/renderer/styles/normalize-view.css` | 修正 | `mainContent` 内コンテナ前提のスタイルに調整 |
| `src/renderer/styles/lrc-editor.css` | 修正 | 同上 |
| `src/renderer/styles/quiz-view.css` | 修正 | 同上 |
| `src/renderer/styles/mtp-browser.css` | 修正 | 同上 |

---

## 実装ステップ

### Step 1：`render` 関数インターフェースの設計

すべてのビューが従う共通インターフェースを定義する。

```js
/**
 * @param {HTMLElement} container - mainContent 要素
 * @param {object} [options] - ビュー固有の引数（表示対象の曲情報など）
 */
function renderXxxView(container, options = {}) {
    container.innerHTML = `...`;
    // イベントリスナーの登録
    // ビュー固有の初期化
}
```

**Wails 版（`src/renderer/`）での採用（2025-04-24 時点）**

- ビュー切り替えは `navigation.js` の `showView(viewId, options)` が **毎回** `clearMainContent()` 実行後、対応する `render*` または `showView` 専用ハンドラを呼び出す。
- ビュー間で共有する `AbortController` により、直前の `signal` を `abort` し、DOM リスナーを一括解除する（歌詞クイズ・ノーマライズ等）。
- 外部 HTML ファイル（`components/*.html`）は廃止し、マークアップは各機能モジュール内の `get*Html` か `*-markup.ts` に集約する。

**完了条件：**
- インターフェース仕様を本ドキュメントに追記し、全ビューが準拠していること。

---

### Step 2：ノーマライズビューの移行

優先度が高く、構造が比較的単純なノーマライズビューから着手する。

#### 2-1. `normalize-view.js` の再設計

```js
// 変更前
export function initNormalizeView() { ... }  // index.html の #normalize-view に描画

// 変更後
export function renderNormalizeView(container) {
    container.innerHTML = getNormalizeViewHtml();
    attachNormalizeViewEvents(container);
}

function getNormalizeViewHtml() {
    return `
        <div class="normalize-view-inner">
            ...（現在の normalize.html の内容）
        </div>
    `;
}
```

#### 2-2. `normalize.html` の削除

`components/normalize.html` を削除し、HTML は `normalize-view.js` 内の `getNormalizeViewHtml()` で生成する。

#### 2-3. CSS の調整

`normalize-view.css` から `position: fixed` や `z-index` を用いたオーバーレイ前提のスタイルを削除し、`.main-content` 内に自然に収まるスタイルに変更する。

**完了条件：**
- `renderNormalizeView(container)` を呼び出すと `mainContent` にノーマライズ UI が描画されること。
- `mainContent` が hidden になっていないこと。
- 既存のノーマライズ機能（解析・ゲイン適用）が正常に動作すること。

---

### Step 3：歌詞編集ビュー（LRC エディタ）の移行

#### 3-1. `lrc-editor.js` の再設計

```js
// 変更前
export function initLrcEditor() { ... }

// 変更後
export function renderLrcEditor(container, track) {
    container.innerHTML = getLrcEditorHtml(track);
    attachLrcEditorEvents(container, track);
}
```

#### 3-2. `lrc-editor.html` の削除

#### 3-3. CSS の調整

`lrc-editor.css` のオーバーレイ前提スタイルを削除する。LRC エディタは横幅を最大限使いたい要件があるため、`mainContent` が全幅になるよう CSS で対応する（右サイドバーの折り畳みは別途検討）。

**完了条件：**
- `renderLrcEditor(container, track)` を呼び出すと `mainContent` に LRC 編集 UI が描画されること。
- 同期ハイライト・タイムスタンプ挿入など既存の LRC 編集機能が正常に動作すること。

---

### Step 4：その他の特殊ビューの移行

以下を Step 2・3 と同様のパターンで移行する。

| ビュー | 移行関数 |
|--------|---------|
| クイズビュー | `renderQuizView(container)` |
| MTP ブラウザ | `renderMtpBrowserView(container)` |
| CD リッパー | `renderCdRipView(container)` |
| MTP 転送 | `renderMtpTransferView(container)` |

**完了条件：**
- 各ビューが `mainContent` 内に正常に描画されること。
- 既存の各機能が正常に動作すること。

---

### Step 5：`navigation.js` の `showView()` 統一

`isSpecialView` 分岐を削除し、全ビューを統一フローで処理する。

```js
// 変更前（概念コード）
function showView(viewId) {
    const specialViews = [...];
    if (specialViews.includes(viewId)) {
        mainContent.classList.add('hidden');
        document.getElementById(viewId).classList.remove('hidden');
        callSpecialViewInit(viewId);
    } else {
        mainContent.classList.remove('hidden');
        renderNormalView(viewId);
    }
}

// 変更後
const VIEW_RENDERERS = {
    'track-view':      () => renderTrackView(mainContent),
    'album-view':      () => renderAlbumView(mainContent),
    'artist-view':     () => renderArtistView(mainContent),
    'situation-view':  () => renderSituationView(mainContent),
    'playlist-view':   () => renderPlaylistView(mainContent),
    'normalize-view':  () => renderNormalizeView(mainContent),
    'lrc-editor-view': (opts) => renderLrcEditor(mainContent, opts.track),
    'quiz-view':       () => renderQuizView(mainContent),
    'mtp-browser-view':() => renderMtpBrowserView(mainContent),
    'cd-rip-view':     () => renderCdRipView(mainContent),
};

function showView(viewId, options = {}) {
    const renderer = VIEW_RENDERERS[viewId];
    if (!renderer) return;
    cleanupCurrentView();         // 現ビューのイベントリスナーを解除
    renderer(options);
    updateActiveNavLink(viewId);
    state.activeViewId = viewId;
}
```

**完了条件：**
- `showView()` 内に `hidden` クラスの付け外しや `isSpecialView` 判定が存在しないこと。
- すべてのビュー遷移が `VIEW_RENDERERS` マップ経由で行われること。

---

### Step 6：`component-loader.js` の廃止と `renderer.js` の整理

#### 6-1. `component-loader.js` を廃止

外部 HTML の事前ロードが不要になるため、`component-loader.js` を削除（または空のスタブに変更）する。

#### 6-2. `renderer.js` の起動シーケンスを整理

```js
// 変更前
async function initApp() {
    await loadAllComponents();   // ← 削除
    initElements();
    initNormalizeView();         // ← 削除（showView 時に描画）
    initQuiz();                  // ← 削除
    ...
}

// 変更後
async function initApp() {
    initElements();
    initUI();
    initNavigation();
    initEventListeners();
    initSettings();
    initModal();
    initPlayer();
    initIPC();
    showView('track-view');      // 初期ビュー表示
}
```

**完了条件：**
- アプリ起動時に特殊ビューの HTML が事前ロードされないこと。
- 起動シーケンスがシンプルになっていること。

---

### Step 7：`index.html` のクリーンアップ

特殊ビュー用の `<div>` タグを `index.html` から削除する。

```html
<!-- 削除対象 -->
<div id="lrc-editor-view" class="view-container hidden"></div>
<div id="normalize-view" class="view-container hidden"></div>
<div id="quiz-view" class="view-container hidden"></div>
<div id="mtp-browser-view" class="view-container hidden"></div>
<div id="mtp-transfer-view" class="view-container hidden"></div>
<div id="cd-rip-view" class="view-container hidden"></div>
```

**完了条件：**
- `index.html` に `view-container hidden` を持つ `<div>` が存在しないこと。

---

### Step 8：CSS の統合整理

#### 削除するスタイルパターン

各特殊ビューの CSS から以下を削除する：

```css
/* オーバーレイ前提のスタイル（削除対象） */
.view-container {
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    z-index: 100;
}
```

#### 追加・修正するスタイルパターン

特殊ビューが `mainContent` 内に収まるよう、各ビューに `height: 100%` と `overflow-y: auto` を設定する。

```css
/* mainContent 内コンテナの共通スタイル */
.normalize-view-inner,
.lrc-editor-inner,
.quiz-view-inner {
    height: 100%;
    overflow-y: auto;
    padding: 16px;
}
```

**完了条件：**
- 特殊ビューが `mainContent` 内でスクロール可能な状態で表示されること。
- 各ビューの UI が視覚的に崩れていないこと。

---

## ビュー遷移フロー（統一後）

```
ユーザーが左サイドバーのナビリンクまたはボタンをクリック
  ↓
showView(viewId, options?) を呼び出し
  ↓
cleanupCurrentView() で現ビューのリスナーを解除
  ↓
VIEW_RENDERERS[viewId](options) を実行
  ↓
mainContent.innerHTML = <新しいビューの HTML>
  ↓
イベントリスナーを再登録
state.activeViewId を更新
nav-link の active クラスを更新
```

---

## リスクと対策

| リスク | 対策 |
|-------|------|
| LRC エディタが横幅を必要とする | `mainContent` の幅制約を CSS 変数化し、`lrc-editor-view` 時は右サイドバーを自動折り畳みする option を `showView()` に追加する |
| 各特殊ビューの HTML が長大で JS 可読性が低下する | HTML 文字列生成を `createXxxHtml()` 関数に分離し、ファイルを `xxx-view-html.js` として分割する |
| Step 移行中の中間状態で動作が壊れる | 各 Step を完了させてからコミット。Step 単位でブランチを切ってもよい |
| `MTP 転送ビュー` が `MTP ブラウザビュー` から遷移する入れ子構造 | `renderMtpTransferView(container)` を `renderMtpBrowserView()` 内から呼び出す形にし、`showView()` からの直接呼び出しは不要とする |

---

## 完了の定義

- [ ] すべての特殊ビューが `mainContent` 内に描画され、`mainContent` が hidden になる箇所がない
- [ ] `showView()` に `isSpecialView` 判定または `hidden` クラス操作が存在しない
- [ ] `component-loader.js` および `components/*.html` ファイルが削除されている
- [ ] `index.html` に `.view-container.hidden` の `<div>` が存在しない
- [ ] 全ビューの UI が視覚的に正常であること（手動確認）
- [ ] 既存の全機能（ノーマライズ・LRC 編集・クイズ・MTP・CD リッピング）が正常に動作すること
- [ ] `package.json` のバージョンが `PhaseVer +1` に更新されていること

---

## 関連ファイル

- [`src/renderer/js/core/navigation.js`](../Electron_Based_UX-Music/src/renderer/js/core/navigation.js)
- [`src/renderer/js/component-loader.js`](../Electron_Based_UX-Music/src/renderer/js/component-loader.js)
- [`src/renderer/renderer.js`](../Electron_Based_UX-Music/src/renderer/renderer.js)
- [`src/renderer/index.html`](../Electron_Based_UX-Music/src/renderer/index.html)
- [`src/renderer/styles/layout.css`](../Electron_Based_UX-Music/src/renderer/styles/layout.css)
