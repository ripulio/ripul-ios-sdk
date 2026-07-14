import SwiftUI
import MarkdownUI

// Native twins of the starter block set. Each mirrors the props contract of
// its web counterpart in chrome-extension/src/cms/blocks/registry/ — same
// prop names, same binding semantics, idiomatic native presentation.

// MARK: - text

struct CmsTextBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let content = runtime.resolveString(block: block, propKey: "content") ?? ""
        Text(content)
            .font(font(for: block.props.string("element") ?? "p"))
            .foregroundColor(typographyColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typographyColor: Color {
        runtime.color(block.props.object("typography")?.string("color")) ?? .primary
    }

    private func font(for element: String) -> Font {
        switch element {
        case "h1": return .largeTitle.weight(.bold)
        case "h2": return .title.weight(.bold)
        case "h3": return .title2.weight(.semibold)
        case "h4": return .title3.weight(.semibold)
        case "h5": return .headline
        case "h6": return .subheadline.weight(.semibold)
        case "caption": return .caption
        default: return .body
        }
    }
}

// MARK: - markdown

struct CmsMarkdownBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let source = runtime.resolveString(block: block, propKey: "source") ?? ""
        Markdown(source)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - image

struct CmsImageBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let src = runtime.resolveString(block: block, propKey: "src") ?? ""
        let caption = runtime.resolveString(block: block, propKey: "caption")
        let shape = block.props.string("shape") ?? "square"

        VStack(alignment: .leading, spacing: 6) {
            if let url = URL(string: src), !src.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: block.props.string("fit") == "cover" ? .fill : .fit)
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .clipShape(imageShape(shape))
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func imageShape(_ shape: String) -> CmsAnyShape {
        switch shape {
        case "circle": return CmsAnyShape(Circle())
        case "rounded": return CmsAnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        default: return CmsAnyShape(Rectangle())
        }
    }
}

/// Type-erased Shape — SwiftUI.AnyShape ships in iOS 16; the SDK targets iOS 15.
struct CmsAnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        makePath = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect)
    }
}

// MARK: - divider

struct CmsDividerBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let label = runtime.resolveString(block: block, propKey: "label")
        if let label, !label.isEmpty {
            HStack(spacing: 12) {
                line
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
                line
            }
        } else {
            Divider()
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - section (container block with optional heading)

struct CmsSectionBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let heading = runtime.resolveString(block: block, propKey: "heading"), !heading.isEmpty {
                Text(heading)
                    .font(.title3.weight(.semibold))
            }
            if let children = block.children {
                CmsBlockContainerView(container: children)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - container (pure layout block)

struct CmsContainerBlockView: View {
    let block: CmsBlock

    var body: some View {
        if let children = block.children {
            CmsBlockContainerView(container: children)
        }
    }
}
