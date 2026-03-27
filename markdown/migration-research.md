# Electron から Wails への移行難易度調査レポート (最終版)

## 1. 総合評価
**難易度：低 (Low) 〜 中 (Medium)**

**理由**: 
MTP および CD リッピング機能を Go へ移植せず、**「必要な時だけ起動する Node.js サイドカー」** として維持するハイブリッド戦略を採用することで、主要なリスクが解消されました。

## 2. 移行戦略

### A. ハイブリッド・サイドカー戦略
- **対象**: MTP 転送、CD リッピング（普段使わない機能）
- **方針**: `Kalam.js` 等の既存 Node.js コードをそのまま活用し、Wails (Go) から必要時のみ起動。
- **ディレクトリ構成**:
    ```
    src/sidecars/
    ├── mtp/           # MTP転送用
    │   ├── index.js
    │   └── package.json
    └── cd-rip/        # CDリッピング用
        ├── index.js
        └── package.json
    ```

### B. Go への完全移行対象
| 機能 | 移行方針 |
| :--- | :--- |
| **YouTube 連携** | Go ライブラリ (`kkdai/youtube` 等) で再実装 |
| **Discord RPC** | Go ライブラリ (`hugolgst/rich-go` 等) で再実装 |
| **音声解析** | goroutine による並列処理で高速化 |
| **UI 通信** | Wails バインディングへ置換 |

### C. 進捗状況
- [x] Phase 1: バックエンドロジック分離 (Go Sidecar 移行済み)
- [ ] Phase 2: サイドカー・ブリッジの実装
- [ ] Phase 3: Wails への完全統合

## 3. 残存作業

| 項目 | 難易度 | 内容 |
| :--- | :--- | :--- |
| **UI 移植** | 低 | HTML/CSS 流用。IPC を Wails 形式に置換。 |
| **サイドカー連携** | 中 | Go から Node.js を起動し JSON-RPC で通信。 |
| **YouTube Go 移植** | 中 | Go ライブラリの動作検証と統合。 |
| **パッケージング** | 中 | サイドカー用 node_modules の同梱設定。 |

---
調査更新日: 2026-01-20
調査担当: Antigravity
