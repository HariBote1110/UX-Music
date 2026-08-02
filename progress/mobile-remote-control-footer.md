# UX Music Mobile: Remote Control タブのトランスポートがフッターに重なるバグ

## Decision
- `RemoteControlScreen.swift` の `body` は `NavigationStack { ZStack { NowPlayingAmbientBackground(...); controlsView } }` という構造で、`NowPlayingAmbientBackground` は内部で `.ignoresSafeArea()` を呼んでいる。
- `ZStack` は最も大きい子のサイズにレイアウトサイズを合わせるため、背景がZStackの兄弟として存在すると、その `.ignoresSafeArea()` によるフルスクリーンサイズが `ZStack` 全体（＝トランスポート行を含む `controlsView` も）のレイアウトサイズを支配してしまう。結果として `HomeRootView` が `.safeAreaInset(edge: .bottom)` / `tabViewBottomAccessory` で確保しているミニプレイヤー＋タブバー分の余白が `controlsView` 側の `VStack` に反映されず、`Spacer(minLength:)` が画面最下端まで押し広げられて再生ボタン一式がフッターの裏に沈み込んでいた。
- 修正: 背景を ZStack の兄弟ではなく `.background { NowPlayingAmbientBackground(palette: nil) }` として付与する形に変更。`.background()` は付与先のプライマリコンテンツ（`controlsView`/`unreachableView` を包む `Group`）のレイアウトサイズには影響しないため、`controlsView` は親から渡された（safe area 分だけ縮小された）フレームで正しくレイアウトされ、`.ignoresSafeArea()` の効果は背景の描画範囲にのみ適用される。

## Alternatives considered
- `controlsView` に固定の bottom padding（ミニプレイヤー＋タブバーの実測高さ相当）を追加する案 → 却下。フッターの実高さは端末・OSバージョン（`tabViewBottomAccessory` の有無）で変わりうり、ハードコードは脆い。根本原因（ZStackのサイズがignoresSafeAreaな背景に引きずられる）を直すほうが他のタブとの整合性も保てる。
- `controlsView` 全体を `ScrollView` にラップして常にスクロールで回避する案 → 却下。今回のケースは根本原因を直せば固定レイアウトのままで解決するため、UXの変化（センタリングが崩れる等）を避けた。

## Constraints / Gotchas
- SwiftUI の `ZStack` はサイズを持たない `.background()` 系の背景と、サイズ計算に参加する通常の子要素との違いに注意。`.ignoresSafeArea()` を持つビューを ZStack の直接の子として重ねると、意図せず兄弟ビューのレイアウトサイズまで「フルスクリーン化」してしまうことがある。同様の環境光背景（`NowPlayingAmbientBackground`）を使う他の画面を新設する際も、背景は `.background()` 経由で付与すること。
