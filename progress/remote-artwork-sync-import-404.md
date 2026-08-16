# リモートアートワークが同期インポート曲で全滅する問題

## 決定
- 症状: TV/モバイルのリモート閲覧でアルバムアートが全てプレースホルダ（Apple TVシミュレータでの実機検証中に発見）。
- 真因: `/v1/remote/songs` が公開する `artworkId` の導出で、`hashStemFromArtworkFilename` が64桁小文字hexのファイル名しか受理しなかった。同期インポートのアートワーク実ファイルは `dev_<deviceId>-<uuid>.webp`（ユーザー環境では1142件）のため全て弾かれ、実在しないアルバムハッシュ（`computeArtworkIDForRemoteFallback`）にフォールバックして `remoteArtworkHandler` が404を返していた。
- 修正: 安全な文字集合（`A-Za-z0-9._-`、先頭ドット禁止、パス区切り文字は集合外）を検証する `isServableArtworkStem` を導入し、これを通る実ファイル名stemをそのままIDとして公開。`remoteArtworkHandler` のガードも同じ検証に統一（ID空間拡大に伴うトラバーサル/隠しファイル探査を構造的に遮断）。64hexのスキャナ命名は文字集合の部分集合なので挙動不変。
- アルバムハッシュへのフォールバックは「artworkオブジェクト自体が無い曲」のみに残置（挙動不変）。

## 制約・注意点
- 検証環境: Apple TVシミュレータ + `wails build` した最新デスクトップアプリ + 実ライブラリ810曲。ペアリングは `/v1/pairing/start`→`confirm` をHTTPで直接叩いてトークンを取得し、TVシムのUserDefaultsに `server_config` を注入する方法で自動化できる。
- `/Applications/UX-Music.app` は古いビルドで `/v1` API非搭載。検証には `build/bin/UX-Music.app` を使うこと。
