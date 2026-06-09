# Lyrics sync sidecar (`lyrics_sync`)

依存関係の性質上、このプロジェクトでは **CPython 3.10〜3.12 のみ**を公式にサポートしています（`requires-python = ">=3.10,<3.13"`）。

## いちばん簡単なローカルセットアップ（推奨）

```bash
brew install python@3.12    # 未導入なら
make lyrics-sync-python
```

`scripts/setup-lyrics-sync-python.sh` は **`brew install python@3.12` のパスを優先**して `.venv` を作成します。  
過去に **Python 3.14 で作った `python/.venv`** が残っている場合は、その場で検出して **削除のうえ再作成**します。

手動で作り直すだけなら:

```bash
rm -rf python/.venv && make lyrics-sync-python
```

明示したいとき:

```bash
PYTHON_FOR_VENV="$(brew --prefix python@3.12)/bin/python3" ./scripts/setup-lyrics-sync-python.sh
```

完了後に **`wails dev` を再起動**。Go は `python/.venv` を自動検出します（環境変数は基本不要）。

- 強制的に別のインタープリタにしたいときのみ `UX_MUSIC_PYTHON`

## Smoke check（GPU なし・ダミー）

```bash
UX_MUSIC_LYRICS_SYNC_DUMMY=1 PYTHONPATH=python python3 -m lyrics_sync --request <<<'{"songPath":"/dev/null","lines":["hello"]}'
```

## 「brew で 3.12 を入れたが動かない」とき

よくある原因は **PATH の `python3` がまだ 3.14 のまま**、`python/.venv` も昔のビルドのままという状態です。

1. 上記 `rm -rf python/.venv && make lyrics-sync-python`
2. アプリ側で **`UX_MUSIC_LYRICS_SYNC_DUMMY` を付けていないか**確認（付いていると本処理ではバージョン検証を省略しますが、本番では使わない）

本番実行時、アプリが選んだ Python が **3.10〜3.12 でない場合**は、設定どおりインストールするより先にエラーを返します（コンソールにログ）。

## Windows

`.venv\Scripts\python.exe` をプロジェクトの `python` 直下に置けば自動検出されます。
