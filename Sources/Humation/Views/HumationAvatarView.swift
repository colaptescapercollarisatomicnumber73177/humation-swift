@preconcurrency import CoreGraphics
import SwiftUI

// MARK: - Humation Avatar View
//
// Renders a resolved humation avatar natively via the cached bitmap pipeline.
// Cross-platform (iOS + macOS): displays a `CGImage` through
// `Image(decorative:scale:)`. A synchronous memory-cache peek avoids a skeleton
// flash; `Equatable` lets grids skip redundant work. The rendered bitmap is
// keyed to the current design so a changing `resolved` never shows a stale image.

public struct HumationAvatarView: View, Equatable {
    public let resolved: ResolvedHumation
    public let size: CGFloat
    /// Optional framing override — pass a part-focused crop so a slot's
    /// thumbnails frame the part being edited (nil = avatar head-shot).
    public var crop: HumationManifest.ViewBox?

    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (key: String, image: CGImage)?

    public init(resolved: ResolvedHumation, size: CGFloat, crop: HumationManifest.ViewBox? = nil) {
        self.resolved = resolved
        self.size = size
        self.crop = crop
    }

    public var body: some View {
        Group {
            if let image = displayImage {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(skeletonColor)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: taskID) { await load() }
    }

    private var pixels: Int {
        HumationBucket.pixels(forPoint: size, scale: displayScale)
    }

    private var taskID: String {
        HumationImageProvider.cacheKey(resolved, pixels: pixels, crop: crop)
    }

    private var displayImage: CGImage? {
        let key = taskID
        // Only trust the rendered bitmap if it matches the CURRENT design.
        if let rendered, rendered.key == key { return rendered.image }
        return HumationImageProvider.memoryImage(forKey: key)
    }

    private var skeletonColor: Color {
        if resolved.background != "transparent", let rgba = HumationRGBA(hex: resolved.background) {
            return Color(red: rgba.r, green: rgba.g, blue: rgba.b)
        }
        return Color(white: 0.95)
    }

    private func load() async {
        let key = taskID
        if let cached = HumationImageProvider.memoryImage(forKey: key) {
            rendered = (key, cached)
            return
        }
        let image = await HumationImageProvider.shared.image(
            for: resolved, pixels: pixels, crop: crop
        )
        if !Task.isCancelled, let image {
            rendered = (key, image)
        }
    }

    public nonisolated static func == (lhs: HumationAvatarView, rhs: HumationAvatarView) -> Bool {
        lhs.resolved == rhs.resolved && lhs.size == rhs.size && lhs.crop == rhs.crop
    }
}
