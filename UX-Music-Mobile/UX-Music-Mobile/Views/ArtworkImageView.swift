import SwiftUI

struct ArtworkImageView: View {
    let urlString: String
    var cornerRadius: CGFloat = 6
    var size: CGFloat? = 48

    var body: some View {
        Group {
            if urlString.isEmpty {
                placeholder
            } else if let u = URL(string: urlString) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
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
