# 初回再生時にライブラリのスクロール位置がリセットされる不具合の修正

## 根本原因

`Views/HomeRootView.swift` の `uxMusicTabMiniPlayer(isEnabled:)`（`TabView` に `.tabViewBottomAccessory`
を適用する private extension）が、`isEnabled` を `if/else` で分岐して modifier 自体の適用有無を
切り替えていた:

```swift
if #available(iOS 26.1, *) {
    if isEnabled {
        self.tabViewBottomAccessory { content() }
    } else {
        self
    }
}
```

`isEnabled` は `HomeRootView.showMiniPlayerAccessory`（`model.player.currentSong != nil`）から来る。
アプリ起動直後は `nil` なので `else self` 分岐、最初の曲を再生した瞬間に `nil → non-nil` へ一度だけ
反転し `if self.tabViewBottomAccessory { … }` 分岐に切り替わる。この if/else は `TabView` を含む
サブツリー全体の**構造的アイデンティティ**を変えるため、SwiftUI はその瞬間に `TabView` 以下を
まるごと再構築する。その結果、ライブラリ一覧（`LocalLibraryScreen` の `ScrollView`/`LazyVStack`)
のスクロール位置が失われる。セッション中に一度（`nil → non-nil` に反転する最初の再生時）だけ発生する。

## アイデンティティ安定の不変条件

`TabView` を「`isEnabled` が変化すると分岐が入れ替わる if/else」の内側に置いてはいけない。
`isEnabled` の反転をまたいで `TabView` の構造的アイデンティティが一定であることが、スクロール位置
維持の必要条件。同時に、何も再生していない間は空のグラスカプセルが表示されてはならない（後述）。

## これまでの試行と、今回効いた方法

- **以前の実装**（今回のコミット以前）: `isEnabled` で `.tabViewBottomAccessory` の適用有無を
  if/else で切り替え。コード内コメントに残っていた通り、これは「以前の試行」の結果でもある —
  `.tabViewBottomAccessory` を常時適用したまま中身だけ `EmptyView`／高さ0の `Color.clear` にする
  方式を一度試し、システムが modifier の存在だけでカプセル（グラス背景の丸みを帯びたバー）を
  描画してしまい、何も再生していなくても空のカプセルが浮いて見える問題があったため、
  「modifier ごと外す」if/else に落ち着いていた、という経緯。
- **今回採用した方法**: iOS 26.1 SDK の `SwiftUI.swiftinterface` を確認したところ、
  `tabViewBottomAccessory(content:)` に加えて **`tabViewBottomAccessory(isEnabled: Bool, content:)`**
  という専用オーバーロードが存在することを確認した（`View` extension、iOS 26.1+ 限定）。
  これは modifier 自体は常に1回だけ適用し、`isEnabled` で表示/非表示だけをシステム側に
  委譲できる API。`HomeRootView.swift` の該当箇所を次のように単一呼び出しへ変更した:

  ```swift
  self.tabViewBottomAccessory(isEnabled: isEnabled) { content() }
  ```

  if/else による分岐がなくなったため `TabView` のアイデンティティは `isEnabled` の反転をまたいで
  安定する。

## 実機検証（シミュレータ、ヘッドレスCLI）

`xcodebuild build` → `xcrun simctl install/launch` → `xcrun simctl io booted screenshot` で
アプリ起動直後（何も再生していない状態）のスクリーンショットを確認した。タブバーの上に空の
カプセルは表示されておらず、`isEnabled: false` の間はアクセサリが完全に非表示になっていることを
確認できた。

**未検証**: スクロール位置がまたがって保持されるかどうかは、ライブラリにある程度の曲数のデータが
ないと確認できないため、シミュレータのヘッドレス検証だけでは確認できていない。実機（または
十分なライブラリを持つシミュレータ環境）でユーザー側の確認が必要。

## 変更ファイル

- `UX-Music-Mobile/UX-Music-Mobile/Views/HomeRootView.swift` — `uxMusicTabMiniPlayer` の
  iOS 26.1+ 分岐を `tabViewBottomAccessory(isEnabled:content:)` の単一呼び出しに変更。
