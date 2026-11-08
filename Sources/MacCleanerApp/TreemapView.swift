import SwiftUI
import AppKit
import MacCleanerCore

@MainActor
public struct TreemapView: View {
    private static let maxBlocks = 80
    private static let tailColor = RGBColor(0x45, 0x4B, 0x54)

    public let items: [ExploreItem]
    @Binding public var hoverItem: ExploreItem?

    @State private var hoverLocation: CGPoint?

    public init(items: [ExploreItem], hoverItem: Binding<ExploreItem?>) {
        self.items = items
        self._hoverItem = hoverItem
    }

    private struct Block {
        let rect: CGRect
        let item: ExploreItem?
        let rgbColor: RGBColor
        let name: String
        let sub: String
        let tip: String
    }

    private func computeBlocks(in size: CGSize) -> [Block] {
        let positive = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard !positive.isEmpty, size.width > 4, size.height > 4 else {
            return []
        }

        let head = Array(positive.prefix(Self.maxBlocks))
        let tail = Array(positive.dropFirst(Self.maxBlocks))
        var values = head.map { Double($0.size) }
        if !tail.isEmpty {
            let tailSum = tail.reduce(0.0) { $0 + Double($1.size) }
            values.append(tailSum)
        }

        let rects = Treemap.layout(values, RectD(x: 0, y: 0, w: Double(size.width), h: Double(size.height)))
        var blocks: [Block] = []
        blocks.reserveCapacity(rects.count)

        for i in 0..<head.count {
            let it = head[i]
            let r = rects[i]
            let cgRect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            let clickHint = it.isFolder ? "\nClick to open" : ""
            blocks.append(
                Block(
                    rect: cgRect,
                    item: it,
                    rgbColor: it.rgbColor,
                    name: it.name,
                    sub: "\(it.sizeText) · \(it.percentText)",
                    tip: "\(it.name)\n\(it.sizeText) (\(it.percentText))\(clickHint)"
                )
            )
        }

        if !tail.isEmpty, let lastRect = rects.last {
            let sum = tail.reduce(Int64(0)) { $0 + $1.size }
            let cgRect = CGRect(x: lastRect.x, y: lastRect.y, width: lastRect.w, height: lastRect.h)
            blocks.append(
                Block(
                    rect: cgRect,
                    item: nil,
                    rgbColor: Self.tailColor,
                    name: "\(tail.count) smaller items",
                    sub: Format.size(sum),
                    tip: "\(tail.count) smaller items\n\(Format.size(sum)) together"
                )
            )
        }

        return blocks
    }

    public var body: some View {
        GeometryReader { geo in
            let blocks = computeBlocks(in: geo.size)
            Canvas { context, _ in
                for b in blocks {
                    let r = CGRect(
                        x: b.rect.origin.x + 1,
                        y: b.rect.origin.y + 1,
                        width: max(0, b.rect.width - 2),
                        height: max(0, b.rect.height - 2)
                    )
                    guard r.width >= 1, r.height >= 1 else { continue }

                    let isHot = (b.item != nil && b.item === hoverItem)
                    let fillColor = isHot ? b.rgbColor.lightened(0.22) : b.rgbColor.color
                    let path = Path(roundedRect: r, cornerRadius: 4)
                    context.fill(path, with: .color(fillColor))
                    if isHot {
                        context.stroke(path, with: .color(.white), lineWidth: 2)
                    }

                    if r.width >= 58 && r.height >= 24 {
                        context.drawLayer { layer in
                            layer.clip(to: path)
                            let titleText = Text(b.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            layer.draw(
                                titleText,
                                in: CGRect(x: r.minX + 6, y: r.minY + 5, width: max(1, r.width - 12), height: 18)
                            )

                            if r.height >= 46 {
                                let subText = Text(b.sub)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(.white.opacity(0.82))
                                layer.draw(
                                    subText,
                                    in: CGRect(x: r.minX + 6, y: r.minY + 23, width: max(1, r.width - 12), height: 16)
                                )
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    hoverLocation = pt
                    let hit = blocks.first { $0.rect.contains(pt) }
                    if hit?.item !== hoverItem {
                        hoverItem = hit?.item
                    }
                case .ended:
                    hoverLocation = nil
                    hoverItem = nil
                }
            }
            .onTapGesture { location in
                if let hit = blocks.first(where: { $0.rect.contains(location) }),
                   let item = hit.item,
                   item.isFolder {
                    item.navigate()
                }
            }
            .contextMenu {
                if let item = hoverItem {
                    Button("Show in Finder") {
                        item.reveal()
                    }
                    if item.showDelete {
                        Button("Delete…") {
                            item.delete()
                        }
                        .disabled(!item.canDelete)
                    }
                }
            }
            .help(hoverItem.map { "\($0.name) — \($0.sizeText) (\($0.percentText))" } ?? "")
        }
    }
}
