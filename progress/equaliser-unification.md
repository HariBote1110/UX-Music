# グラフィックEQのサイドバー/設定画面統一

## Decision
- サイドバーEQタブ（右カラムの `EQ` タブ、`#equalizer-view`）が旧・簡易EQ（Bass/Mid/Treble
  の3スライダー）のみで、設定画面のグラフィックEQ（10バンド・カーブエディタ）と機能差が
  あった問題を解消するため、両者を1本の共有コンポーネントへ統一した。
- `src/renderer/js/ui/equalizer/eq-maths.ts`: DOMに触れない純粋計算のみを切り出し
  （周波数⇔x座標、dB⇔y座標、最近傍バンドのヒット判定、プリセット→バンド、旧3バンド→
  10バンドの折り込み計算）。単体テスト（`eq-maths.test.ts`）で先にRedを書いてから実装。
- `src/renderer/js/ui/equalizer/graphic-equaliser.ts`: `mountGraphicEqualiser(container, mode, callbacks)`
  が実際のDOM（ヘッダー行＝トグル/プリセット/リセット、canvasカーブエディタ、バンド別dB
  読み取り表示）を構築する。`container` ごとに1インスタンスを `WeakMap` で管理し、同じ
  container への再呼び出しは既存インスタンスを破棄してから作り直すため冪等。
  `ResizeObserver` でキャンバスのサイズをコンテナ実寸＋`devicePixelRatio`から再計算し、
  リサイズ時に再描画する。
- 状態の単一情報源は `state.equalizerSettings.bands`（10要素配列）。旧 `bass`/`mid`/`treble`
  フィールドは、初回ロード時に一度だけ `migrateLegacySimpleSettings()` で `bands` へ折り込み、
  以後は 0 のまま維持する（`eq-maths.ts` にテスト付きで実装）。`applyCurrentSettings()` は
  `bands` だけを見て音声グラフへ反映するようになり、旧 `applyCurrentSettings` にあった
  3バンド→10バンドの合成ロジックはコンポーネント初期化時の一度限りの移行処理に一本化された。
- `src/renderer/js/ui/equalizer.ts` は薄いオーケストレーション層になり、
  `renderEqualizer()`（サイドバー用、`elements.equalizerView` に描画）と
  `renderGraphicEQ(container?)`（設定画面用）の2つのエントリーポイントを持つ。
  両方とも内部で `mountGraphicEqualiser` を呼ぶだけで、コールバック
  （`getState`/`onBandsChange`/`onPresetChange`/`onReset`/`onToggleActive`/`onCommit`）は
  `equalizer.ts` 側で共有オブジェクトとして1つ定義し、両インスタンスに同じものを渡す。
  一方の操作（プリセット選択・バンドドラッグ・トグル）で `state.equalizerSettings` を
  更新した直後に `refreshAllInstances()` を呼ぶことで、もう一方の描画済みインスタンスにも
  即座に反映される。
- バンドドラッグ中の保存呼び出しは 200ms デバウンス（`saveSettingsDebounced`）。
  ドラッグ確定（mouseup）・プリセット変更・トグル切替・リセットは全て `onCommit` を経由し、
  同じデバウンス経路で `musicApi.saveSettings` に到達する。
- 旧設定画面の「詳細設定...」ボタンは廃止した。サイドバーEQタブ自体が設定画面と同じ
  10バンド・カーブエディタを表示するようになったため、別画面へ誘導する理由がなくなった
  （設定エージェントへの通知イベントは実装していない。もし設定画面のEQセクションから
  サイドバーへ戻る導線が必要になった場合は、別途相談のうえ追加する）。
- `renderGraphicEQ()` の `container` 引数は省略可能にした（省略時は `#graphic-eq-container`
  を探す）。設定エージェント側の `init-settings.ts`（並行編集中のため本エージェントは
  触れていない）が既存の `renderGraphicEQ()`（引数なし呼び出し）のままでもビルドが壊れない
  ようにするための後方互換。設定エージェントがEQセクション用のコンテナを用意でき次第、
  `renderGraphicEQ(container)` へ更新すれば、そのコンテナに直接マウントされる。

## フッター重なりの修正
- `src/renderer/styles/views.css` の `::after` スペーサー（`--footer-height` 変数を使う
  仕組み。`#music-list`/`#queue-list`/`#lyrics-view` 等と同じ）に `#equalizer-view` を追加。
  `js/ui/ui.ts` の `updateListSpacer()` が再生バーの高さから `--footer-height` を算出して
  `:root` に設定する既存の仕組みをそのまま利用しているため、`ui.ts` 側の変更は不要だった。

## Alternatives considered
- サイドバー版だけ簡易3スライダーを残し、設定画面版だけ10バンドにする案は、そもそもの
  課題（「サイドバーEQタブが同じ10バンドを扱えていない」）を解決しないため却下。
- 「詳細設定...」ボタンを残してカスタムイベントで設定画面を開かせる案も検討したが、
  サイドバー自体が完全な10バンドエディタになった以上、冗長な導線になるため見送った。

## Constraints / Gotchas
- `equalizer.ts` は `index.html` を編集できない制約下で実装しているため、`#equalizer-view`
  配下のDOMは全て `graphic-equaliser.ts` が実行時に構築する。設定画面側も同様に、EQセクション
  のコンテナ要素だけを用意して `renderGraphicEQ(container)` を呼べば残りは自動生成される。
- `graphic-equaliser.ts` はテスト対象外（DOM操作＋canvas描画の統合コード）。ロジックは
  可能な限り `eq-maths.ts` に切り出してテストしている。
- ビルド確認中、`init-settings.ts` から参照している `renderGraphicEQ` のシグネチャ互換は
  上記の通り optional 引数で担保したが、設定エージェントの `settings-store.ts` /
  `settings-page.ts` がまだ存在しないため、`npm test` / `tsc --noEmit` の一部スイート
  （`settings-store.test.ts`、`settings-page.test.ts`）は本エージェントの変更と無関係に
  赤のままだった（並行作業中のファイル不足によるもの）。EQ関連のテスト・型チェックは
  すべて緑。
