import FocusCore
import SwiftUI

struct DescriptionView: View {
    let markdown: String
    /// Freshly signed image URLs from GitHub's rendered HTML; used when they line up with the Markdown images.
    var freshImageURLs: [String] = []

    var body: some View {
        let blocks = DescriptionParser.blocks(from: markdown)
        let imageCount = blocks.filter(\.isImage).count
        let useFresh = freshImageURLs.count == imageCount
        var imageIndex = 0
        let items: [(id: Int, block: DescriptionBlock)] = blocks.enumerated().map { offset, block in
            guard case .image(let url, let alt) = block else { return (offset, block) }
            defer { imageIndex += 1 }
            return (offset, .image(url: useFresh ? freshImageURLs[imageIndex] : url, alt: alt))
        }

        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.id) { item in
                switch item.block {
                case .text(let text):
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let url, let alt):
                    RemoteImage(urlString: url, alt: alt)
                }
            }
        }
    }
}

struct RemoteImage: View {
    let urlString: String
    let alt: String

    var body: some View {
        if let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Link(destination: url) {
                        image.resizable().scaledToFit()
                            .frame(maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                case .failure:
                    Link(destination: url) { Label(alt.isEmpty ? "Open image" : alt, systemImage: "photo") }
                default:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !alt.isEmpty {
            Label(alt, systemImage: "photo").foregroundStyle(.secondary)
        }
    }
}
