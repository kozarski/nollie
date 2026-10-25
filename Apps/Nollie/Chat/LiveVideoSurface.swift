@preconcurrency import AVFoundation
import CoreMedia
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where a live picture is shown. `LiveWatch` hands it each frame as it arrives.
@MainActor
protocol LiveDisplay: AnyObject {
    /// Shows a frame at once. False when the display had to start over first and the frame was
    /// dropped: it needs a keyframe.
    func show(_ sample: CMSampleBuffer, keyframe: Bool) -> Bool
    /// Drops anything not yet shown and the picture on screen too, so an older run's picture
    /// can never come back as this one's.
    func clear()
}

/// The live picture: a view backed by a sample buffer display layer, stretched to the frame
/// WatchView already fitted to the picture's shape.
struct LiveVideoSurface {
    let watch: LiveWatch

    final class Coordinator {
        let watch: LiveWatch
        init(watch: LiveWatch) { self.watch = watch }
    }

    func makeCoordinator() -> Coordinator { Coordinator(watch: watch) }

    @MainActor
    private func made(_ view: LiveVideoView) -> LiveVideoView {
        view.lost = { [weak watch] in watch?.displayLost() }
        watch.attach(view)
        return view
    }
}

#if os(iOS)
extension LiveVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> LiveVideoView { made(LiveVideoView()) }
    func updateUIView(_ view: LiveVideoView, context: Context) {}
    static func dismantleUIView(_ view: LiveVideoView, coordinator: Coordinator) { coordinator.watch.detach(view) }
}
#else
extension LiveVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> LiveVideoView { made(LiveVideoView()) }
    func updateNSView(_ view: LiveVideoView, context: Context) {}
    static func dismantleNSView(_ view: LiveVideoView, coordinator: Coordinator) { coordinator.watch.detach(view) }
}
#endif

#if os(iOS)
typealias LivePlatformView = UIView
#else
typealias LivePlatformView = NSView
#endif

final class LiveVideoView: LivePlatformView, LiveDisplay {
    /// The display had to start over by itself (a decoder lost in the background, say).
    var lost: (() -> Void)?
    private var observers: [any NSObjectProtocol] = []

    #if os(iOS)
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    #else
    let displayLayer = AVSampleBufferDisplayLayer()
    override func makeBackingLayer() -> CALayer { displayLayer }
    #endif

    init() {
        super.init(frame: .zero)
        #if os(iOS)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        #else
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        #endif
        displayLayer.videoGravity = .resize
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                                            object: displayLayer.sampleBufferRenderer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverIfNeeded() }
        })
        #if os(iOS)
        // Coming back from the background: the decoder may have been taken away meanwhile.
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startOver() }
        })
        #else
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startOver() }
        })
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            #if os(macOS)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            #endif
        }
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var needsFlush: Bool { renderer.status == .failed || renderer.requiresFlushToResumeDecoding }

    func show(_ sample: CMSampleBuffer, keyframe: Bool) -> Bool {
        if needsFlush {
            renderer.flush()
            // Only a keyframe can start the decoder again.
            guard keyframe else { return false }
        }
        renderer.enqueue(sample)
        return true
    }

    func clear() { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }

    private func recoverIfNeeded() {
        guard needsFlush else { return }
        startOver()
    }

    private func startOver() {
        renderer.flush()
        lost?()
    }
}
