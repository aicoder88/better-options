import AppKit

@MainActor
final class VolumeHUDController {
    private let panel: NSPanel
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "0%")
    private let titleLabel = NSTextField(labelWithString: "Volume")
    private var hideWorkItem: DispatchWorkItem?
    private var visibilityRevision = 0
    private let contentView = NSView(frame: .zero)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .alertPanel

        contentView.frame = panel.contentView?.bounds ?? .zero
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        contentView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.cornerRadius = 24
        contentView.layer?.masksToBounds = true
        panel.contentView = contentView

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.86)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.isEnabled = false
        slider.controlSize = .large
        slider.allowsTickMarkValuesOnly = false
        slider.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(slider)
        contentView.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),

            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            slider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            slider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),

            valueLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 12),
            valueLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            valueLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])
    }

    func show(volume: Float) {
        let percentage = Int((min(max(volume, 0), 1) * 100).rounded())
        slider.doubleValue = Double(percentage)
        valueLabel.stringValue = "\(percentage)%"

        positionPanel()
        hideWorkItem?.cancel()
        visibilityRevision += 1
        let revision = visibilityRevision

        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hide(revision: revision)
        }
        self.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hideWorkItem)
    }

    private func hide(revision: Int) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.visibilityRevision == revision else {
                        return
                    }
                    self.panel.orderOut(nil)
                }
            }
        )
    }

    private func positionPanel() {
        guard let screen = screenForCurrentPointer() ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let frame = panel.frame
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (frame.width / 2)
        let y = visibleFrame.maxY - frame.height - 84
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenForCurrentPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }
}
