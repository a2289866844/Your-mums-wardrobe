import AppKit
import Darwin

MainActor.assumeIsolated {
    // A file lock also covers unbundled development builds, whose bundle
    // identifier differs but whose clipboard backing files are shared.
    let support = ClipboardStore.defaultFolder.deletingLastPathComponent()
    do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
    catch { fputs("wardrobe could not create its storage folder.\n", stderr); exit(1) }
    let lockFD = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { exit(1) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); exit(0) }
    defer { close(lockFD) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
