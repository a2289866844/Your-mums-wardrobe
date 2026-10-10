import Foundation

/// New screenshots use a fixed preview duration, independently of the
/// pointer-away grace period used by deliberate manual reveals.
struct CapturePreview {
    private var deadline: Date?

    mutating func start(at now: Date) { deadline = now.addingTimeInterval(3) }
    mutating func cancel() { deadline = nil }

    mutating func shouldRetract(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
