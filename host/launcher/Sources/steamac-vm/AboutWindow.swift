import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Available from the application menu both before boot and while the VM is running.
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { close() }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown && event.keyCode == kVK_Escape {
                close()
            } else {
                super.sendEvent(event)
            }
        }
    }

    private var panel: Panel?
    private var eventMonitor: Any?

    @objc func show(_ sender: Any?) {
        if let panel { panel.makeKeyAndOrderFront(sender); return }
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
        guard let screen = owner?.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame
        // Keep the original card size and leave room for its exterior shadow on small displays.
        let k = min(0.8, available.width / (708 + 2 * AboutCard.shadowMargin))
        let host = NSHostingView(rootView: AboutCard(k: k))
        let size = host.fittingSize
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        self.panel = panel
        panel.title = String(localized: "About Stella")
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.hasShadow = false // The card draws its own exterior shadow.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
        panel.delegate = self
        let anchor = owner?.frame.intersection(available) ?? available
        let center = anchor.isEmpty ? available : anchor
        let frame = NSRect(x: center.midX - size.width / 2, y: center.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(panel.constrainFrameRect(frame, to: screen), display: false)
        let margin = AboutCard.shadowMargin * k
        let cardShape = StellaInsetLayer.continuousPath(in: NSRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin), radius: 30 * k)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak panel] event in
            guard let panel else { return event }
            if event.window === panel && cardShape.contains(event.locationInWindow) { return event }
            panel.close()
            return nil
        }
        panel.displayIfNeeded()
        panel.makeKeyAndOrderFront(sender)
    }

    func windowDidResignKey(_ notification: Notification) { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        panel = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}

private struct AboutCard: View {
    static let shadowMargin: CGFloat = 108
    let k: CGFloat
    private let upstream = URL(string: "https://github.com/fxgl/steamac")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let logo = StellaBrand.onDark {
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: 172.3 * k, height: 24.6 * k)
                        .accessibilityLabel(Text(verbatim: "Stella"))
                }
                Spacer()
                Text("Version \(UpdateChecker.currentVersion)")
                    .font(Font(StellaBrand.monoMedium(size: 18 * k)))
            }
            .padding(.bottom, 25 * k)
            Text(StellaBrand.introduction)
                .fontWeight(.light)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 22 * k)
            Text("Acknowledgements").accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12 * k)
            Text("1. Steamac (what this app is based on)\n2. SteamOS")
                .fontWeight(.light)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.leading, 4 * k)
                .padding(.bottom, 22 * k)
            Text("Links").accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12 * k)
            VStack(alignment: .leading, spacing: 6 * k) {
                Link(destination: UpdateChecker.repositoryURL) { Text("Stella GitHub Repo").underline() }
                Link(destination: upstream) { Text("Steamac GitHub Repo").underline() }
            }
            .foregroundStyle(Color(red: 0, green: 0.5, blue: 1))
        }
        .font(.system(size: 18 * k))
        .foregroundStyle(.white)
        .frame(width: 626 * k, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 41 * k)
        .padding(.vertical, 38 * k)
        .padding(Self.shadowMargin * k)
        .background(AboutCardMaterial(designScale: k))
        .fixedSize()
    }
}

private struct AboutCardMaterial: NSViewRepresentable {
    let designScale: CGFloat

    final class Surface: NSView {
        let surface = StellaCardSurface(blending: .behindWindow)
        let cardShadow = StellaCardShadowLayer()
        var designScale: CGFloat = 1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(cardShadow)
            addSubview(surface)
        }

        required init?(coder: NSCoder) { fatalError() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let margin = AboutCard.shadowMargin * designScale
            surface.fit(bounds.insetBy(dx: margin, dy: margin), shadow: cardShadow,
                        designScale: designScale, backingScale: scale)
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Surface { Surface(frame: .zero) }
    func updateNSView(_ view: Surface, context: Context) {
        view.designScale = designScale
        view.needsLayout = true
    }
}
