import Foundation

/// 十字スワイプ UI（Walkman Cross UI）の純ロジック。
/// SwiftUI から切り離した状態遷移・スワイプ方向判定・連続キャンバスのレイアウト計算をまとめる。
/// 見た目を持たないため単体テストで仕様を固定できる。

// MARK: - Direction & Pane

enum MusicDirection: Equatable {
    case left
    case right
    case up
    case down
}

/// 十字配置のペイン。中央が再生画面で、上下左右に各機能が並ぶ。
enum MusicPane: Equatable, CaseIterable {
    case player
    case queue
    case favourites
    case settings
    case library

    var title: String {
        switch self {
        case .player: return "再生画面"
        case .queue: return "キュー"
        case .favourites: return "お気に入り"
        case .settings: return "設定"
        case .library: return "ライブラリ"
        }
    }

    var description: String {
        switch self {
        case .player: return "Now Playing"
        case .queue: return "再生キュー"
        case .favourites: return "お気に入りの曲"
        case .settings: return "EQ と設定"
        case .library: return "プレイリストとアルバム"
        }
    }
}

// MARK: - Navigation state

/// 現在表示しているペインを保持し、スワイプ方向に応じて遷移する。
/// 中央=再生画面を起点に十字移動し、外側ペインからは反対方向で中央へ戻る。
struct MusicNavigationState: Equatable {
    var currentPane: MusicPane

    init(currentPane: MusicPane = .player) {
        self.currentPane = currentPane
    }

    mutating func move(_ direction: MusicDirection) {
        switch (currentPane, direction) {
        case (.player, .left):
            currentPane = .queue
        case (.player, .right):
            currentPane = .favourites
        case (.player, .up):
            currentPane = .library
        case (.player, .down):
            currentPane = .settings
        case (.queue, .right),
             (.favourites, .left),
             (.library, .down),
             (.settings, .up):
            currentPane = .player
        default:
            break
        }
    }
}

// MARK: - Swipe resolver

/// ドラッグ量から遷移方向を判定する。短いスワイプと対角スワイプは無視し、
/// ドラッグ追従の見た目では支配軸のみを残す。
enum MusicSwipeResolver {
    static let threshold: Double = 44
    static let axisDominanceRatio: Double = 1.35

    static func direction(forHorizontal horizontal: Double, vertical: Double) -> MusicDirection? {
        if abs(horizontal) < threshold && abs(vertical) < threshold {
            return nil
        }

        if abs(horizontal) > abs(vertical) {
            guard abs(horizontal) >= abs(vertical) * axisDominanceRatio else {
                return nil
            }
            return horizontal > 0 ? .left : .right
        }

        guard abs(vertical) >= abs(horizontal) * axisDominanceRatio else {
            return nil
        }
        return vertical > 0 ? .up : .down
    }

    static func filteredDragOffset(horizontal: Double, vertical: Double) -> PaneOffset {
        guard let direction = direction(forHorizontal: horizontal, vertical: vertical) else {
            return PaneOffset(x: 0, y: 0)
        }

        switch direction {
        case .left, .right:
            return PaneOffset(x: horizontal, y: 0)
        case .up, .down:
            return PaneOffset(x: 0, y: vertical)
        }
    }
}

// MARK: - Layout

struct PaneOrigin: Equatable {
    let x: Int
    let y: Int
}

struct PaneOffset: Equatable {
    let x: Double
    let y: Double
}

/// 十字に並ぶペインを「連続したキャンバス」として配置するためのレイアウト計算。
/// 非表示ペインは画面外へ送り、ドラッグ中は隣接ペインがその分だけ追従して見える。
enum CrossPlayerLayout {
    static let usesSwipeOnlyNavigationControls = true
    static let horizontalPadding: Double = 0
    static let directionButtonWidth: Double = 0
    static let topContentInset: Double = 64
    static let verticalContentInset: Double = 28
    static let offscreenPageMultiplier: Double = 2
    static let libraryMenuUsesStableTopAnchoring = true
    static let libraryMenuItemMinHeight: Double = 78
    static let libraryMenuIconSize: Double = 28
    static let minimumCardWidth: Double = 320
    static let preferredCardWidth: Double = 520

    static var minimumRequiredWidth: Double {
        horizontalPadding * 2 + directionButtonWidth * 2 + minimumCardWidth
    }

    static func cardWidth(for availableWidth: Double) -> Double {
        let remainingWidth = availableWidth - horizontalPadding * 2
        return min(preferredCardWidth, max(minimumCardWidth, remainingWidth))
    }

    static func origin(for pane: MusicPane) -> PaneOrigin {
        switch pane {
        case .player: return PaneOrigin(x: 0, y: 0)
        case .queue: return PaneOrigin(x: -1, y: 0)
        case .favourites: return PaneOrigin(x: 1, y: 0)
        case .library: return PaneOrigin(x: 0, y: -1)
        case .settings: return PaneOrigin(x: 0, y: 1)
        }
    }

    static func offset(
        for pane: MusicPane,
        currentPane: MusicPane,
        containerWidth: Double,
        containerHeight: Double,
        dragX: Double,
        dragY: Double
    ) -> PaneOffset {
        let paneOrigin = origin(for: pane)
        let currentOrigin = origin(for: currentPane)
        let originDeltaX = paneOrigin.x - currentOrigin.x
        let originDeltaY = paneOrigin.y - currentOrigin.y
        let pageMultiplier = (dragX == 0 && dragY == 0) ? offscreenPageMultiplier : 1

        return PaneOffset(
            x: Double(originDeltaX) * containerWidth * pageMultiplier + dragX,
            y: Double(originDeltaY) * containerHeight * pageMultiplier + dragY
        )
    }
}
