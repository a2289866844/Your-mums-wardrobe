import SwiftUI

struct LibraryToolbar: NSViewRepresentable {
    @ObservedObject var line: Line
    func makeNSView(context: Context) -> LibraryToolbarView { LibraryToolbarView() }
    func updateNSView(_ view: LibraryToolbarView, context: Context) { view.configure(line) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LibraryToolbarView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Only the search field takes keyboard focus.
final class LibraryToolbarView: NSView, NSSearchFieldDelegate {
    let search = ShelfSearchField()
    let scopes = NSSegmentedControl(labels: LibraryScope.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let compactScopes = NSPopUpButton()
    let status = NSTextField(labelWithString: "")
    private weak var line: Line?
    private var focusRequested = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "搜尋歷史、圖片文字…"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.onFocus = { [weak self] in self?.line?.searchFocused = true }
        search.setAccessibilityIdentifier("library-search")
        search.setAccessibilityLabel("搜尋剪貼簿歷史")
        scopes.target = self
        scopes.action = #selector(changeScope)
        scopes.controlSize = .small
        scopes.setAccessibilityIdentifier("library-scopes")
        compactScopes.addItems(withTitles: LibraryScope.allCases.map(\.title))
        compactScopes.target = self
        compactScopes.action = #selector(changeCompactScope)
        compactScopes.controlSize = .small
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for view in [search, scopes, compactScopes, status] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ line: Line) {
        self.line = line
        if search.stringValue != line.libraryQuery { search.stringValue = line.libraryQuery }
        let selected = LibraryScope.allCases.firstIndex(of: line.libraryScope) ?? 0
        if scopes.selectedSegment != selected { scopes.selectedSegment = selected }
        if compactScopes.indexOfSelectedItem != selected { compactScopes.selectItem(at: selected) }
        if status.stringValue != line.libraryStatus {
            let visibilityChanged = status.stringValue.isEmpty != line.libraryStatus.isEmpty
            status.stringValue = line.libraryStatus
            if visibilityChanged { needsLayout = true }
        }
        if status.toolTip != line.libraryStatus { status.toolTip = line.libraryStatus }
        if line.searchFocused && !focusRequested {
            focusRequested = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.line?.searchFocused == true else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self.search)
            }
        } else if !line.searchFocused { focusRequested = false }
    }
    override func layout() {
        super.layout()
        let wide = bounds.width >= 750
        if scopes.isHidden != !wide { scopes.isHidden = !wide }
        if compactScopes.isHidden != wide { compactScopes.isHidden = wide }
        let hideStatus = !wide || status.stringValue.isEmpty
        if status.isHidden != hideStatus { status.isHidden = hideStatus }
        let scopeWidth: CGFloat = wide ? 112 : 66
        let scopeView = wide ? scopes as NSView : compactScopes
        let scopeFrame = NSRect(x: 4, y: 4, width: scopeWidth, height: 24)
        if scopeView.frame != scopeFrame { scopeView.frame = scopeFrame }
        let statusWidth: CGFloat = status.isHidden ? 0 : 150
        let start = scopeWidth + 12
        let searchWidth = max(80, bounds.width - start - statusWidth - 8)
        let searchFrame = NSRect(x: start, y: 3, width: searchWidth, height: 26)
        if search.frame != searchFrame { search.frame = searchFrame }
        if !status.isHidden {
            let statusFrame = NSRect(x: start + searchWidth + 8, y: 8, width: statusWidth - 8, height: 16)
            if status.frame != statusFrame { status.frame = statusFrame }
        }
    }
    func controlTextDidChange(_ obj: Notification) { line?.libraryQuery = search.stringValue }
    func controlTextDidBeginEditing(_ obj: Notification) { focusRequested = true; line?.searchFocused = true }
    func controlTextDidEndEditing(_ obj: Notification) { line?.searchFocused = false; focusRequested = false }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            line?.libraryQuery = ""
            line?.searchFocused = false
            line?.onSearchEnd?()
            window?.makeFirstResponder(nil)
            window?.resignKey()
            return true
        }
        return false
    }
    @objc private func changeScope() {
        guard LibraryScope.allCases.indices.contains(scopes.selectedSegment) else { return }
        line?.libraryScope = LibraryScope.allCases[scopes.selectedSegment]
    }
    @objc private func changeCompactScope() {
        guard LibraryScope.allCases.indices.contains(compactScopes.indexOfSelectedItem) else { return }
        line?.libraryScope = LibraryScope.allCases[compactScopes.indexOfSelectedItem]
    }
}

final class ShelfSearchField: NSSearchField {
    var onFocus: (() -> Void)?
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func focusSearch() {
        onFocus?()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }
    override func mouseDown(with event: NSEvent) { focusSearch(); super.mouseDown(with: event) }
    override func accessibilityPerformPress() -> Bool { focusSearch(); return true }
}
