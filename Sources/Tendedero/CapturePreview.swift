import Foundation

/// New screenshots use a fixed preview duration, independently of the
/// pointer-away grace period used by deliberate manual reveals.
struct CapturePreview {
    private var deadline: Date?

    mutating func start(at now: Date) { deadline = now.addingTimeInterval(3) }
    mutating func cancel() { deadline = nil }

    /// Leave enough time to read Copy/Copied feedback without pinning the shelf.
    mutating func extendForCopyFeedback(at now: Date) {
        guard let deadline else { return }
        self.deadline = max(deadline, now.addingTimeInterval(2))
    }

    mutating func shouldRetract(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
