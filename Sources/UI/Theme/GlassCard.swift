import AppKit
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    private let material: NSVisualEffectView.Material
    private let blendingMode: NSVisualEffectView.BlendingMode
    private let opacity: Double

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        opacity: Double = 1.0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.opacity = opacity.isFinite ? min(max(opacity, 0.0), 1.0) : 1.0
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.alphaValue = CGFloat(opacity)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != .active {
            nsView.state = .active
        }
        let targetAlpha = CGFloat(opacity)
        if abs(nsView.alphaValue - targetAlpha) > 0.001 {
            nsView.alphaValue = targetAlpha
        }
    }
}

struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let opacity: Double
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        padding: CGFloat = 14,
        cornerRadius: CGFloat = 16,
        opacity: Double = 0.88,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.opacity = opacity.isFinite ? min(max(opacity, 0.0), 1.0) : 0.88
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(padding)
            .background {
                ZStack {
                    VisualEffectBackground(
                        material: colorScheme == .dark ? .hudWindow : .underWindowBackground,
                        blendingMode: .behindWindow,
                        opacity: opacity
                    )
                    SenseiPalette.cardSurfaceTint(for: colorScheme, opacity: opacity)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.05 * opacity : 0.24 * opacity),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
                .clipShape(shape)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.22 * opacity : 0.08 * opacity),
                    radius: 10,
                    x: 0,
                    y: 4
                )
            }
            .overlay {
                shape.strokeBorder(
                    SenseiPalette.specularBorderGradient(for: colorScheme),
                    lineWidth: 1
                )
            }
    }
}
