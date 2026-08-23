# H1: ポーラーの無条件書き込みによる再描画

## 目的 / 仮説

`AppModel`の`sidecarPollOnce()`は2秒毎に`/v1/remote/state`をポーリングし、既に
`progress/sidecar-poll-tick-cpu-leak.md`で「値が変わっていなくても無条件に
`@Observable`プロパティへ書き込むと、そのプロパティを読む全ビューが2秒毎に
再評価される」というパターンが特定・修正済み（`SidecarMetadataSnapshot`による
差分ガード）。

今回のタスク文の仮説H1は「同種の無条件書き込みパターンがRemote関連の別ポーラーに
残っていないか」。コードを読んだ時点で有力候補を発見:
`Views/RemoteControlScreen.swift`の`pollOnce()`が2秒毎に`desktopState: [String:
Any]`という**辞書全体**を無条件に代入している（118〜132行目付近）。

```swift
private func pollOnce() async {
    ...
    await MainActor.run {
        hasReceivedState = true
        desktopState = s          // 値が同じでも毎回代入
        errorMessage = nil
    }
}
```

`[String: Any]`は`Equatable`に適合できないため、SwiftUIは新旧の内容を比較できず、
**内容が同一でも参照が変わるたびに`@State`の変更として扱われ、`controlsView`
（アートワークカード・タイトル/アーティストラベル・シークバー・トランスポート行）
全体が2秒毎に再評価される**はず、という仮説。

`AppModel.sidecarPollOnce()`側は既に差分ガード済みなので、Remote(Library)タブ
(`RemoteLibraryScreen`)がこれらのプロパティを読んでいなければ影響を受けない
はず、というのが対照仮説（H1が「Remoteタブ全体」に効くか、「Controlタブ限定」か
の切り分け）。

## 環境

`01-baseline-setup-and-environment.md`と同一（iPhone 17シミュレータ、N=500曲
スタブ、コミット`31ccd80`）。

## 手順

1. アプリを起動しRemote(Library)タブ（`リモート`、Songs/Albums/Playlists
   グリッド）を開いたまま何も操作せず60秒、`ps -o pid,pcpu,rss`を1秒間隔で
   サンプリング。
2. 同一プロセスのままControlタブ（`コントロール`、Stub Track Titleの再生画面）に
   切り替え、同様に60秒アイドルサンプリング。
   （`LazyTabRoot`によりRemote(Library)タブは非表示中も裏でマウントされたまま
   残る — H4の実測条件を兼ねる。）
3. `python3`で中央値・p95・最大値を集計。

コマンド・ログは`mobile_remote_perf_research/tools/baseline_remote_idle.log`・
`baseline_control_idle.log`。

## 結果

| タブ | n | CPU中央値(%) | CPU p95(%) | CPU最大(%) | RSS傾向(60秒) |
|---|---|---|---|---|---|
| Remote (Library, Songs/Albums/Playlistsグリッド) | 60 | 0.3 | 0.6 | 0.8 | 297MB→264MB台で微減、その後横ばい（増加なし） |
| Control (再生中Stub Trackを表示) | 60 | 1.0 | 2.7 | 4.4 | 297〜316MB台で横ばい（増加なし） |

Controlタブは2秒周期でCPUスパイク（0.2%→1.5〜2.7%、まれに4.4%）が明確に観測され、
Remote(Library)タブはそのようなスパイクがほぼ無くほぼ平坦（最大0.8%）だった。
両タブともRSSの単調増加（過去のオリエンテーション/`TimelineView`ストーム系の
再発）は60秒間観測されなかった。

## 結論

- **H1は部分的に採択**: `RemoteControlScreen.pollOnce()`の`desktopState`無条件
  代入は、Controlタブをアイドル表示しているだけでもCPU中央値を実測で
  約3倍（0.3%→1.0%）、p95を約4.5倍（0.6%→2.7%）に押し上げている。2秒周期の
  スパイクという波形自体が、ポーリングTickごとのbody全体再評価という仮説と
  整合する。
- **H1のうち「Remote(Library)タブ全体が同じ問題を持つ」という部分は棄却**:
  `RemoteLibraryScreen`自身はポーラーを持たず、`AppModel.sidecarPollOnce()`は
  既に差分ガード済み（`SidecarMetadataSnapshot`、2026-08-15の修正）で
  `sidecarActive`以外は無条件書き込みが無い。実測でもRemote(Library)タブの
  アイドルCPUはControlタブの1/3程度で、単独では「重い」と言えるレベルではない。
- ユーザー報告の「Remoteタブが全体的に重い」は、Remote LibraryタブとControlタブを
  行き来する運用（`LazyTabRoot`でどちらも裏で生き続ける）を指している可能性が
  高い。Controlタブを一度でも開くと、以後Remoteタブに留まっていてもControlタブの
  2秒スパイクが裏で回り続ける（H4の実測条件と同じ状態で本計測を行っており、
  Remote(Library)タブの値が低いことは「H4による多重化」がH1ほど支配的でない
  ことも示唆する — もしH4が主要因ならRemote(Library)タブ計測時にもControlタブの
  スパイクが漏れて見えるはずだが、実際には見えなかった）。

## 次の一手 / 未検証事項

- `desktopState`を`Equatable`な構造体に置き換え、変更時のみ書き込むガードを
  入れた変種でControlタブアイドルCPUを再計測し、0.3%近辺まで下がるかを検証する
  （本タスクでは実装禁止のため未実施、次工程の`/development`フローで検証すべき）。
- `sidecarActive`単独の無条件書き込み（`AppModel.swift`のコメントにある通り
  positionと同様に毎tick書かれている）が、Sidecar機能を一切使わないユーザーでも
  地味なコストになっていないかは未計測（Sidecar非表示中は`sidecarActive`を
  読むビューが無いため理論上は無害なはずだが、実測での確認はしていない）。
