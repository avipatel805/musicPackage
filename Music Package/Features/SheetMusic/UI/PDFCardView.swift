import SwiftUI

struct PDFCardView: View {
    let item: PDFItem
    let thumbnail: UIImage?

    private static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateStyle = .medium
        return d
    }()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(Self.df.string(from: item.createdAt))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 10)
            .padding(.horizontal, 6)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }
}

