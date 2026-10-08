import AppKit

/// The control plane: a search field over the config's commands. Typing filters, ↑↓ move,
/// ⏎ runs, ⎋ or a click elsewhere closes.
final class Palette: NSObject, NSTextFieldDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    var commands: [Config.Command] = []
    var run: (Config.Command) -> Void = { _ in }
    /// Toggles (always on top) say "on" next to their key while they are on.
    var isOn: (Config.Command) -> Bool = { _ in false }

    private let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 0),
                              styleMask: [.borderless], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let list = NSStackView()
    private(set) var shown: [Config.Command] = []
    private(set) var selected = 0
    private weak var parent: NSWindow?

    var isOpen: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.cgColor
        box.layer?.borderColor = Self.line.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 6

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font(15)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Control Plane", attributes: [.foregroundColor: Self.muted, .font: Self.font(15)])
        field.delegate = self

        list.orientation = .vertical
        list.spacing = 2
        list.alignment = .leading

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Self.line

        let stack = NSStackView(views: [field, rule, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 480),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            list.widthAnchor.constraint(equalTo: field.widthAnchor),
            rule.widthAnchor.constraint(equalTo: field.widthAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        panel.contentView = box
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.close() }
    }

    func open(over window: NSWindow) {
        parent = window
        field.stringValue = ""
        filter()
        // Above the parent even when it is always on top.
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
    }

    /// For `--probe`: what typing `query` would show.
    func type(_ query: String) {
        field.stringValue = query
        filter()
    }

    func runSelected() {
        guard shown.indices.contains(selected) else { return }
        let command = shown[selected]
        close()
        run(command)
    }

    // MARK: Filtering and layout

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
        selected = 0
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, command) in shown.enumerated() {
            list.addArrangedSubview(row(command, selected: index == selected, index: index))
        }
        if shown.isEmpty {
            let none = NSTextField(labelWithString: "no matching command")
            none.font = Self.font(13)
            none.textColor = Self.muted
            list.addArrangedSubview(none)
        }
        place()
    }

    private func row(_ command: Config.Command, selected: Bool, index: Int) -> NSView {
        let title = NSTextField(labelWithString: command.title)
        title.font = Self.font(13)
        title.textColor = selected ? Self.green : .white
        let key = NSTextField(labelWithString: [isOn(command) ? "on" : nil, command.key.map(Self.symbols)]
            .compactMap { $0 }.joined(separator: "  "))
        key.font = Self.font(13)
        key.textColor = Self.muted
        let row = Row(views: [title, NSView(), key])
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.wantsLayer = true
        row.layer?.cornerRadius = 3
        row.layer?.backgroundColor = selected ? Self.line.cgColor : nil
        row.onClick = { [weak self] in
            self?.selected = index
            self?.runSelected()
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 456).isActive = true
        return row
    }

    /// Centered on the parent window, a fifth of the way down.
    private func place() {
        guard let parent, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 5 - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard !shown.isEmpty else { return }
        selected = (selected + step + shown.count) % shown.count
        render()
    }

    // MARK: Look (header.js colors)

    private static let line = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
    private static let green = NSColor(red: 0x6d / 255, green: 0xd0 / 255, blue: 0x8c / 255, alpha: 1)
    private static let muted = NSColor(red: 0x93 / 255, green: 0x99 / 255, blue: 0xb2 / 255, alpha: 1)

    private static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: "0xProto Nerd Font", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    }

    static func symbols(_ shortcut: Shortcut) -> String {
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined() + shortcut.key.uppercased()
    }

    private final class Row: NSStackView {
        var onClick: () -> Void = {}
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
