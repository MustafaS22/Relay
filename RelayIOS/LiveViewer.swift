import AVFoundation
import RelayCore
import SwiftUI

struct LiveViewer: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var code = ""
    @State private var controls = true
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var magnification = 1.0
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let viewport = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                  height: geometry.size.height + insets.top + insets.bottom)
            let fit = CGSize(width: min(viewport.width, viewport.height * model.aspect),
                             height: min(viewport.height, viewport.width / model.aspect))
            ZStack {
                video(viewport: viewport, fit: fit)
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: (viewport.width / 2) - insets.leading, y: (viewport.height / 2) - insets.top)
                    .ignoresSafeArea(.keyboard)
                if model.phase != .live {
                    statusPanel.padding(24)
                }
                if controls || model.phase != .live {
                    VStack {
                        header
                        Spacer()
                        if model.authorized { toolbar(fit: fit) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .onChange(of: viewport) { _, _ in pan = .zero }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(controls ? .visible : .hidden)
        .statusBarHidden(!controls)
    }

    private func video(viewport: CGSize, fit: CGSize) -> some View {
        let scale = min(8, max(1, zoom * magnification))
        let position = bounded(CGSize(width: pan.width + drag.width, height: pan.height + drag.height),
                               fit: fit, viewport: viewport, scale: scale)
        return ZStack {
            PlaybackLayer(player: model.layer)
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(scale)
                .offset(position)
                .accessibilityLabel("Mac display")
                .accessibilityHidden(model.phase != .live)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        zoom = zoom > 1 ? 1 : 2
                        pan = .zero
                    }
                }
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { controls.toggle() }
                }
                .simultaneousGesture(MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        zoom = min(8, max(1, zoom * value.magnification))
                        pan = bounded(pan, fit: fit, viewport: viewport, scale: zoom)
                    })
                .simultaneousGesture(DragGesture()
                    .updating($drag) { value, state, _ in if zoom > 1 { state = value.translation } }
                    .onEnded { value in
                        pan = bounded(CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height),
                                      fit: fit, viewport: viewport, scale: zoom)
                    })
                .accessibilityHidden(true)
        }
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button("Disconnect", systemImage: "xmark", action: model.disconnect)
                .labelStyle(.iconOnly)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
            Text(model.name).font(.headline).lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if model.phase == .live {
                Label("Live", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color(red: 0.66, green: 0.10, blue: 0.19), in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    private func toolbar(fit: CGSize) -> some View {
        VStack(spacing: 8) {
            if model.showStats, let stats = model.stats {
                VStack(spacing: 4) {
                    Text("\(stats.captured) capture · \(stats.encoded) encode · \(model.decoded) display fps")
                    Text(String(format: "%.2f Mbps · %d drops", Double(stats.bitrate) / 1_000_000, stats.dropped))
                    if let rtt = model.rtt, let latency = model.latency {
                        Text(String(format: "%.0f ms RTT · %.0f ± %.0f ms estimated video latency", rtt, latency, rtt / 2))
                    }
                }
                .font(.caption2.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 6) {
                Button(model.phase == .paused ? "Resume" : "Pause",
                       systemImage: model.phase == .paused ? "play.fill" : "pause.fill", action: model.togglePause)
                    .labelStyle(.iconOnly)
                    .frame(width: 48, height: 48)
                Menu("Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                    Button("Fit to Screen") { zoom = 1; pan = .zero }
                    if model.sourceSize.width > 0, fit.width > 0 {
                        Button("Actual Pixels") {
                            let density = model.layer.contentsScale
                            zoom = min(8, max(1, model.sourceSize.width / (fit.width * density)))
                            pan = .zero
                        }
                    }
                    Button("2× Zoom") { zoom = 2; pan = .zero }
                }
                .labelStyle(.iconOnly).frame(width: 48, height: 48)
                Menu("Displays", systemImage: "display") {
                    ForEach(model.displays) { display in
                        Button { model.choose(display.id) } label: {
                            if model.selected == display.id {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                }
                .labelStyle(.iconOnly).frame(width: 48, height: 48)
                .disabled(model.displays.isEmpty)
                Menu("Quality", systemImage: "slider.horizontal.3") {
                    ForEach(Quality.allCases) { quality in
                        Button { model.choose(quality) } label: {
                            if quality == model.quality { Label(quality.title, systemImage: "checkmark") } else { Text(quality.title) }
                        }
                    }
                }
                .labelStyle(.iconOnly).frame(width: 48, height: 48)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .connecting, .authenticating, .starting, .reconnecting, .approval:
                ProgressView().tint(.white)
            case .paused:
                Image(systemName: "pause.circle").font(.title)
            case .code:
                Image(systemName: "lock.shield").font(.title)
            case .failed:
                Image(systemName: "wifi.exclamationmark").font(.title)
            case .live: EmptyView()
            }
            Text(model.detail).font(.callout).multilineTextAlignment(.center)
            if model.phase == .code {
                TextField("Six-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(.title2, design: .monospaced))
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                Button("Verify Code") {
                    model.submit(code)
                    code = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != 6)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.phase)
    }

    private func bounded(_ position: CGSize, fit: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        let x = max(0, (fit.width * scale - viewport.width) / 2)
        let y = max(0, (fit.height * scale - viewport.height) / 2)
        return CGSize(width: max(-x, min(position.width, x)), height: max(-y, min(position.height, y)))
    }
}

private struct PlaybackLayer: UIViewRepresentable {
    let player: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PlaybackView {
        let view = PlaybackView()
        view.player = player
        view.layer.addSublayer(player)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlaybackView, context: Context) {}

    final class PlaybackView: UIView {
        var player: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            player?.frame = bounds
            player?.contentsScale = traitCollection.displayScale
            CATransaction.commit()
        }
    }
}
