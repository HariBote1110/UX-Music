import SwiftUI
import UIKit

struct ArtworkImageView: View {
    let artworkId: String
    let urlString: String
    var cornerRadius: CGFloat = 6
    var size: CGFloat? = 48

    @State private var loaded: UIImage?

    private var taskIdentity: String { "\(artworkId)\u{1E}\(urlString)" }

    var body: some View {
        Group {
            if urlString.isEmpty {
                placeholder
            } else if let img = loaded {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                loadingPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: taskIdentity) {
            loaded = nil
            guard !urlString.isEmpty else { return }
            let img = await WearRemoteArtworkImageLoader.loadUIImage(artworkId: artworkId, urlString: urlString)
            loaded = img
        }
    }

    private var loadingPlaceholder: some View {
        let s = size ?? 48
        return ZStack {
            Color(white: 0.15)
            ProgressView()
                .tint(.secondary)
                .scaleEffect(min(1, s / 48))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        let s = size ?? 48
        return ZStack {
            Color(white: 0.15)
            Image(systemName: "music.note")
                .font(.system(size: s * 0.35))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Large header artwork (album / playlist) using the same Wear preview disk cache as grid thumbnails.
struct WearCachedHeroArtworkView: View {
    let artworkId: String
    let urlString: String
    var height: CGFloat = 280

    @State private var loaded: UIImage?

    private var taskIdentity: String { "\(artworkId)\u{1E}\(urlString)\u{1E}hero" }

    var body: some View {
        Group {
            if urlString.isEmpty {
                Color(white: 0.12)
            } else if let img = loaded {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.12)
                    ProgressView()
                        .tint(.white.opacity(0.45))
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: taskIdentity) {
            loaded = nil
            guard !urlString.isEmpty else { return }
            loaded = await WearRemoteArtworkImageLoader.loadUIImage(artworkId: artworkId, urlString: urlString)
        }
    }
}
