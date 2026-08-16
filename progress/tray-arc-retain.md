# メニューバー・トレイアイコン非表示（ARC未有効）

## 決定
- `server/tray_darwin.go` の `#cgo CFLAGS` に `-fobjc-arc` を追加し、`server/tray_darwin.m` をARCとしてコンパイルするよう修正した。
- cgoはObjective-Cソースをデフォルトで**MRC（手動retain/release）**としてコンパイルする。`-x objective-c` だけを指定しても言語をObjective-Cに切り替えるだけでARCは有効化されない。
- `tray_darwin.m` はARCスタイル（明示的な `retain`/`release`/`autorelease`/`dealloc` を一切書かない前提）で実装されていたため、MRCコンパイル下では致命的な不具合を起こしていた。
  - `UXTrayCreateOnMainThread` 内の `uxTrayStatusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:...]` は、Cocoaの命名規約上 `statusItemWithLength:` が**autoreleased**（+0）オブジェクトを返す。ARCならこの代入時に暗黙のretainが挿入されるが、MRCではretainが一切発生しないため、staticポインタ `uxTrayStatusItem` に代入された直後、そのイベントループの周回でオートリリースプールが drain されるとオブジェクトは解放される。結果としてトレイアイコンは表示されないか、一瞬出てすぐ消え、以後は解放済みポインタへの未定義アクセスになっていた。
  - 同様に `uxTrayTarget`（`[[UXTrayTarget alloc] init]`）、`NSMenu`（`[[NSMenu alloc] init]`）、`UXTrayAddItem` が返す各 `NSMenuItem`、`NSImage`（`[[NSImage alloc] initWithData:]`）はいずれも+1オブジェクトだがMRCでは対応する `release` が無くリークしていた。`ux_tray_destroy` も `uxTrayStatusItem` を release せずnilにしていた。
- `#cgo CFLAGS` はcgoの仕様上パッケージ内の全C/Objective-Cファイルへ連結適用されるため、`tray_darwin.go` 1ファイルへのフラグ追加で同パッケージの `server/os_media_darwin.m` も同時にARC化される。`os_media_darwin.m` を確認したところ `retain]`/`release]`/`autorelease]`/`dealloc` の呼び出しや、unbridgedなCFTypeRefキャスト、直接の `NSAutoreleasePool` 使用は無く、ARC下でも安全にコンパイルできることを `go build ./...` / `go vet ./server/...` / `go test ./server/...` の実行で確認した。
- フラグは `tray_darwin.go` にのみ実体を置き、`os_media_darwin.go` 側にはコメントで「ARCは tray_darwin.go の #cgo CFLAGS 経由でパッケージ全体に効いている」旨を明記するに留めた（同一フラグの重複指定によるビルド破壊リスクを検証コストごと避けるため）。

## 検討した代替案
- **サージカルなMRC修正案**（各オブジェクトへ明示的に `retain`/`release` を追加する方式）は不採用。ARC化に比べて、修正漏れ・二重release・タイミングの取り違えのリスクが高く、かつ将来この`.m`ファイルにコードを足す人がARCスタイルの記法（`[[NSMenuItem alloc] init]` をrelease無しで書く等）へ戻ってしまうと同じ不具合が再発する。ARC化はこのクラスのバグを構造的に再発不能にする。
- `-fobjc-arc` を両方の `.go` ファイルに重複指定する案は、cgoが同一フラグの重複をどう扱うか未検証のリスクを負うだけで実利がないため見送った（`go build` は1箇所指定のみで両`.m`ファイルに正しく適用されることを確認済み）。

## 制約・注意点
- `#cgo CFLAGS` はパッケージ単位で連結される。今後 `server` パッケージへ新しい `.m` ファイルを追加する場合、そのファイルもARCとしてコンパイルされる点に注意。MRCで書きたい特別な事情がある場合は、当該ファイルだけを別パッケージに分離するなどの対応が必要。
- 逆に、既存の `.m` ファイルへ手動 `retain`/`release`/`autorelease`/`dealloc` や unbridged な `CFTypeRef` キャストを書き足すと、ARCの二重解放・コンパイルエラーの原因になる。ARC前提で統一する。
- バージョン番号（`src/renderer/package.json`）は別エージェント管轄のため未更新。今回は致命的バグ修正のためPhaseVerを1つ進めSubVerをaへリセットすべき変更。
