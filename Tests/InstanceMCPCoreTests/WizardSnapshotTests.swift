import AppKit
import XCTest
@testable import InstanceMCPCore
@testable import oab_computer

/// Renders every wizard page and every Browser tools state to PNG files for a human to read. It runs only when
/// `OAB_SNAPSHOT_DIR` names a directory; each state is drawn twice, with the app appearance light and dark, because
/// the wizard window is forced light and must look the same either way.
@MainActor
final class WizardSnapshotTests: XCTestCase {
    private var dir: String?

    override func setUpWithError() throws {
        dir = ProcessInfo.processInfo.environment["OAB_SNAPSHOT_DIR"]
        try XCTSkipIf(dir == nil, "set OAB_SNAPSHOT_DIR to render snapshots")
        try FileManager.default.createDirectory(atPath: dir!, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    private func png(_ view: NSView, _ name: String, system: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(dir!)/\(name)-system-\(system).png"))
    }

    private func forEachSystem(_ body: (String) throws -> Void) rethrows {
        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            try body(label)
        }
        NSApp.appearance = nil
    }

    private var plan: PlaywrightInstallPlan {
        PlaywrightInstallPlan(manifest: .embedded, arch: .current, root: URL(fileURLWithPath: "/tmp/oab-snapshot-root"))
    }

    func testBrowserStates() throws {
        var states: [(String, BrowserPageModel)] = []
        states.append(("browser-1-idle", BrowserPageModel(installState: .notInstalled)))
        states.append(("browser-2-external", BrowserPageModel(installState: .notInstalled, externalProvider: true)))
        var installing = BrowserPageModel(installState: .notInstalled)
        _ = installing.beginInstall()
        installing.progress(PlaywrightInstallProgress(step: .downloadChromium, fraction: 0.4))
        states.append(("browser-3-progress", installing))
        var offline = BrowserPageModel(installState: .notInstalled)
        _ = offline.beginInstall()
        _ = offline.finished(.failure(.offline))
        states.append(("browser-4-offline", offline))
        var disk = BrowserPageModel(installState: .notInstalled)
        _ = disk.beginInstall()
        _ = disk.finished(.failure(.notEnoughDisk(needed: 900_000_000, available: 100_000_000)))
        states.append(("browser-5-disk", disk))
        states.append(("browser-6-installed", BrowserPageModel(installState: .installed(id: "x", updateAvailable: false, stale: false))))
        states.append(("browser-7-installed-update", BrowserPageModel(installState: .installed(id: "x", updateAvailable: true, stale: false), externalProvider: true)))
        try forEachSystem { system in
            for (name, model) in states {
                let window = WizardWindowFactory.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 620))
                let page = BrowserPageView()
                page.translatesAutoresizingMaskIntoConstraints = false
                window.contentView!.addSubview(page)
                NSLayoutConstraint.activate([
                    page.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
                    page.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                ])
                page.render(model: model, plan: plan)
                try png(window.contentView!, name, system: system)
            }
        }
    }

    func testWizardPages() throws {
        let suite = UserDefaults(suiteName: "oab-snapshot-\(UUID().uuidString)")!
        let store = SetupWizardStore(defaults: suite)
        let relaunch = RelaunchCoordinator(store: store, launch: { false }, terminate: {})
        let exposure = TailnetExposure(defaults: suite, loginDetected: true, backendPort: 8787,
                                       runner: { _, _, _ in .launchFailed }, candidates: { [] }, sleep: { _ in })
        let installer = PlaywrightInstaller.standard(root: URL(fileURLWithPath: "/tmp/oab-snapshot-root"),
                                                     stopManaged: {}, verifyServing: { false }, onRemoved: {}, log: { _ in })
        let tools = BrowserToolsController(installer: installer, store: BrowserToolsStore(defaults: suite),
                                           signIn: { _, _ in .null }, log: { _ in })
        let controller = PermissionSetupWindowController(store: store, relaunch: relaunch, exposure: exposure, browserTools: tools)
        try forEachSystem { system in
            for (index, name) in ["wizard-1-core", "wizard-2-optional", "wizard-3-browser", "wizard-4-tailnet"].enumerated() {
                controller.show()
                // A test host has no permissions granted, so the controller stays on page 1. The four page
                // stacks are the content view's subviews in build order; show exactly one of them.
                let pages = controller.window!.contentView!.subviews.compactMap { $0 as? NSStackView }
                XCTAssertEqual(pages.count, 4)
                for (i, page) in pages.enumerated() { page.isHidden = i != index }
                try png(controller.window!.contentView!, name, system: system)
            }
        }
    }
}
