import SwiftUI
import UIKit
import JellyampCore
import JellyfinBackend

/// Dominant artwork colour per image, computed off the main thread and cached.
/// Used to tint the visualizer so it matches the cover it is drawn over.
actor ArtworkPalette {
    static let shared = ArtworkPalette()

    private var cache: [String: RGBColor] = [:]
    private var order: [String] = []
    private let limit = 64

    /// - Returns: nil when the track has no artwork or it could not be loaded.
    func tint(for track: Track, session: JellyfinSession) async -> RGBColor? {
        // Tracks of one album share a cover, so key on the image, not the track.
        let key = "\(track.albumID ?? track.id)|\(track.imageTag ?? "")"
        if let cached = cache[key] { return cached }
        // A thumbnail is plenty for a colour and is usually already cached by
        // the server's image pipeline.
        guard let url = ImageURLBuilder.trackImageURL(track: track, maxWidth: 96, session: session),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let pixels = Self.pixels(from: data),
              let dominant = DominantColor.dominant(rgba: pixels) else { return nil }
        let color = DominantColor.vivid(dominant)
        cache[key] = color
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return color
    }

    /// Decodes and downsamples to 32×32 RGBA. Runs on the actor's executor
    /// (a background thread), never on the main thread.
    private static func pixels(from data: Data, side: Int = 32) -> [UInt8]? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// Animation state of one visualizer: smoothing and peak-hold live in Core
/// (`SpectrumSmoother`); this object just carries them from frame to frame.
/// Not `@Published` on purpose — the `TimelineView` drives redraws.
final class VisualizerRenderer: ObservableObject {
    struct Frame {
        var levels: [Float]
        var peaks: [Float]
        var waveform: [Float]
    }

    private var smoother = SpectrumSmoother()
    private var waveform: [Float] = []
    private var lastDate: Date?

    func frame(at date: Date, store: SpectrumStore?) -> Frame {
        let dt = lastDate.map { date.timeIntervalSince($0) } ?? (1.0 / 30)
        lastDate = date
        let snapshot = store?.snapshot() ?? (levels: [], waveform: [])
        // No fresh audio (paused, tap removed): fall towards silence.
        let bandCount = max(smoother.levels.count, SpectrumAnalyzer.bandCount)
        let target = snapshot.levels.isEmpty ? [Float](repeating: 0, count: bandCount) : snapshot.levels
        smoother.update(target: target, dt: dt)

        if snapshot.waveform.isEmpty {
            waveform = waveform.map { $0 * 0.8 }
        } else if waveform.count == snapshot.waveform.count {
            // Half-way blend: steadier than the raw block, still lively.
            for index in waveform.indices {
                waveform[index] += (snapshot.waveform[index] - waveform[index]) * 0.5
            }
        } else {
            waveform = snapshot.waveform
        }
        return Frame(levels: smoother.levels, peaks: smoother.peaks, waveform: waveform)
    }
}

/// FFT visualizer fed by the engine's mixer tap, drawn with `Canvas`.
///
/// It only costs anything while it can be seen: the tap is retained and the
/// timeline runs only when the view is on screen, the app is active, Low
/// Power Mode is off and Reduce Motion is not requested.
struct VisualizerView: View {
    let style: VisualizerStyle
    let tint: Color
    let isPlaying: Bool

    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var renderer = VisualizerRenderer()
    @State private var isVisible = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Playback stopped long enough ago that the bars have fallen to rest.
    @State private var settled = false
    @State private var holdsTap = false

    private var spectrumSource: AudioSpectrumProviding? {
        container.player as? AudioSpectrumProviding
    }

    private var isActive: Bool {
        style != .off && isVisible && scenePhase == .active && !lowPowerMode && !reduceMotion
    }

    var body: some View {
        let store = spectrumSource?.spectrum
        let renderer = self.renderer
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || settled)) { timeline in
            Canvas { context, size in
                let frame = renderer.frame(at: timeline.date, store: store)
                switch style {
                case .off:
                    break
                case .bars:
                    drawBars(frame, in: &context, size: size)
                case .wave:
                    drawWave(frame, in: &context, size: size)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear {
            isVisible = true
            updateTap(active: style != .off && scenePhase == .active && !lowPowerMode && !reduceMotion)
        }
        .onDisappear {
            isVisible = false
            updateTap(active: false)
        }
        .onChange(of: isActive) { active in
            updateTap(active: active)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: isPlaying) {
            if isPlaying {
                settled = false
            } else {
                // Let the bars fall before stopping the render loop.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { settled = true }
            }
        }
    }

    /// Installs the mixer tap while this view is drawing, removes it otherwise.
    private func updateTap(active: Bool) {
        guard active != holdsTap else { return }
        holdsTap = active
        if active {
            spectrumSource?.retainSpectrum()
        } else {
            spectrumSource?.releaseSpectrum()
        }
    }

    private func drawBars(_ frame: VisualizerRenderer.Frame, in context: inout GraphicsContext, size: CGSize) {
        let count = frame.levels.count
        guard count > 0, size.width > 0, size.height > 0 else { return }
        let spacing: CGFloat = max(2, size.width / CGFloat(count) * 0.25)
        let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let capHeight: CGFloat = 3
        let usable = size.height - capHeight
        for index in 0..<count {
            let x = CGFloat(index) * (barWidth + spacing)
            let height = max(2, CGFloat(frame.levels[index]) * usable)
            let bar = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: bar, cornerRadius: min(barWidth / 2, 3)),
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.95), tint.opacity(0.45)]),
                    startPoint: CGPoint(x: x, y: bar.minY),
                    endPoint: CGPoint(x: x, y: bar.maxY)
                )
            )
            if index < frame.peaks.count, frame.peaks[index] > 0.02 {
                let peakY = size.height - capHeight - CGFloat(frame.peaks[index]) * usable
                let cap = CGRect(x: x, y: max(0, peakY), width: barWidth, height: capHeight)
                context.fill(Path(roundedRect: cap, cornerRadius: 1.5), with: .color(Color.white.opacity(0.85)))
            }
        }
    }

    private func drawWave(_ frame: VisualizerRenderer.Frame, in context: inout GraphicsContext, size: CGSize) {
        let points = frame.waveform
        guard points.count > 1, size.width > 0, size.height > 0 else { return }
        let middle = size.height / 2
        // Music rarely swings to full scale; a little gain makes it readable.
        let amplitude = size.height / 2 * 1.6
        let step = size.width / CGFloat(points.count - 1)
        var line = Path()
        for index in points.indices {
            let offset = max(-middle, min(middle, CGFloat(points[index]) * amplitude))
            let point = CGPoint(x: CGFloat(index) * step, y: middle - offset)
            if index == 0 {
                line.move(to: point)
            } else {
                // Midpoint smoothing keeps the trace from looking jagged.
                let previous = CGPoint(
                    x: CGFloat(index - 1) * step,
                    y: middle - max(-middle, min(middle, CGFloat(points[index - 1]) * amplitude))
                )
                let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                line.addQuadCurve(to: mid, control: previous)
                if index == points.count - 1 { line.addLine(to: point) }
            }
        }
        context.stroke(line, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}
