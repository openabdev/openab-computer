import AppKit
import Foundation
import XCTest
@testable import InstanceMCPCore

final class MenuModelTests: XCTestCase {
    private func status(configured: Bool, managesSaved: Bool = true, disabled: String? = nil,
                        state: ReverseAttachClient.State? = .attached) -> SwitchboardStatus {
        SwitchboardStatus.make(state: configured ? state : nil, lastClose: nil, configured: configured, profile: .observe,
                               computer: "Mac", disabledReason: disabled, managesSaved: managesSaved)
    }

    func testReconnectAndForgetAreDisabledWhenNotConfigured() {
        let notConfigured = MenuModel.switchboardEnablement(status(configured: false))
        XCTAssertFalse(notConfigured.reconnect)
        XCTAssertFalse(notConfigured.forget)
        XCTAssertTrue(notConfigured.configure)
        let disabled = MenuModel.switchboardEnablement(status(configured: false, disabled: "secret unreadable"))
        XCTAssertFalse(disabled.reconnect)
        XCTAssertFalse(disabled.forget)
        XCTAssertEqual(MenuModel.switchboardEnablement(nil), SwitchboardMenuEnablement(configure: false, reconnect: false, forget: false))
    }

    func testReconnectAndForgetAreEnabledWhenConfigured() {
        let on = MenuModel.switchboardEnablement(status(configured: true))
        XCTAssertEqual(on, SwitchboardMenuEnablement(configure: true, reconnect: true, forget: true))
        // Dialling from launch flags: the saved files cannot be edited or forgotten, but a reconnect works.
        let flagged = MenuModel.switchboardEnablement(status(configured: true, managesSaved: false))
        XCTAssertEqual(flagged, SwitchboardMenuEnablement(configure: false, reconnect: true, forget: false))
    }

    @MainActor
    func testADisabledItemStaysDisabledInAMenuThatDoesNotAutoEnable() {
        final class Target: NSObject { @objc func act() {} }
        let target = Target()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Reconnect", action: #selector(Target.act), keyEquivalent: "")
        item.target = target
        item.isEnabled = false
        menu.addItem(item)
        menu.update()
        XCTAssertFalse(item.isEnabled)
    }

    func testLaunchdDetectionUsesAJobLabelOnly() {
        XCTAssertTrue(LaunchdJob.isRunByLaunchd(environment: ["XPC_SERVICE_NAME": "dev.openab.instance-mcp"]))
        XCTAssertEqual(LaunchdJob.jobLabel(environment: ["XPC_SERVICE_NAME": "dev.openab.instance-mcp"]), "dev.openab.instance-mcp")
        XCTAssertFalse(LaunchdJob.isRunByLaunchd(environment: [:]))
        XCTAssertFalse(LaunchdJob.isRunByLaunchd(environment: ["XPC_SERVICE_NAME": "0"]), "a terminal session")
        XCTAssertFalse(LaunchdJob.isRunByLaunchd(environment: ["XPC_SERVICE_NAME": ""]))
        XCTAssertFalse(LaunchdJob.isRunByLaunchd(environment: ["XPC_SERVICE_NAME": "application.dev.openab.instance-mcp.1234.5678"]),
                       "an app opened from Finder is not a job that can be booted out")
    }

    func testQuitAndRestartLabelsFollowLaunchd() {
        XCTAssertEqual(MenuModel.quitTitle(underLaunchd: false), "Quit OpenAB Computer")
        XCTAssertEqual(MenuModel.quitTitle(underLaunchd: true), "Quit Agent (stops launchd job)")
        XCTAssertEqual(MenuModel.restartPlan(underLaunchd: true), .exitForKeepAlive)
        XCTAssertEqual(MenuModel.restartPlan(underLaunchd: false), .relaunchCoordinator)
    }

    func testRestartWithoutALaunchdJobUsesTheCoordinatorAndNeverBootsOut() {
        var relaunches = 0, exits = 0
        let started = MenuModel.restart(underLaunchd: false, relaunch: { relaunches += 1; return true }, exitProcess: { exits += 1 })
        XCTAssertTrue(started)
        XCTAssertEqual(relaunches, 1)
        XCTAssertEqual(exits, 0, "the coordinator quits after the new instance starts, not the menu")

        relaunches = 0
        _ = MenuModel.restart(underLaunchd: true, relaunch: { relaunches += 1; return true }, exitProcess: { exits += 1 })
        XCTAssertEqual(relaunches, 0)
        XCTAssertEqual(exits, 1)
    }

    func testTheCoordinatorStillAllowsOneRelaunchPerLaunchAndStartsBeforeQuitting() {
        let defaults = UserDefaults(suiteName: "menu-restart-\(UUID().uuidString)")!
        var events: [String] = []
        let coordinator = RelaunchCoordinator(store: SetupWizardStore(defaults: defaults),
                                              launch: { events.append("launch"); return true },
                                              terminate: { events.append("terminate") })
        XCTAssertTrue(MenuModel.restart(underLaunchd: false,
                                        relaunch: { coordinator.requestRelaunch(page: nil, automatic: false) }, exitProcess: {}))
        XCTAssertFalse(MenuModel.restart(underLaunchd: false,
                                         relaunch: { coordinator.requestRelaunch(page: nil, automatic: false) }, exitProcess: {}))
        XCTAssertEqual(events, ["launch", "terminate"])
    }

    func testQuitBootsOutOnlyALaunchdJob() {
        var booted: [String] = [], exits = 0
        MenuModel.quit(jobLabel: nil, bootout: { booted.append($0) }, exitProcess: { exits += 1 })
        XCTAssertEqual(booted, [])
        XCTAssertEqual(exits, 1)
        MenuModel.quit(jobLabel: "dev.openab.instance-mcp", bootout: { booted.append($0) }, exitProcess: { exits += 1 })
        XCTAssertEqual(booted, ["dev.openab.instance-mcp"])
        XCTAssertEqual(exits, 1)
    }

    func testTheTailnetMenuShowsStateAndTheMatchingAction() {
        XCTAssertEqual(MenuModel.tailnetMenu(offered: true, publicURL: nil),
                       TailnetMenu(stateLine: "Tailnet access: Off", actionTitle: "Allow tailnet access…", action: .allow))
        XCTAssertEqual(MenuModel.tailnetMenu(offered: true, publicURL: "https://m.ts.net:8444/mcp"),
                       TailnetMenu(stateLine: "Tailnet access: On", actionTitle: "Turn Off Tailnet Access", action: .turnOff))
    }

    func testWizardFootersWithAndWithoutTheTailnetPage() {
        let granted = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .granted)
        let noFDA = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .denied)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: granted), .done)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: noFDA), .skip)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: granted, tailnetPage: true), .continueToTailnet)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: noFDA, tailnetPage: true), .skipToTailnet)
        XCTAssertEqual(WizardModel.footerAction(page: .tailnet, snapshot: granted, tailnetPage: true, tailnetOn: false), .skip)
        XCTAssertEqual(WizardModel.footerAction(page: .tailnet, snapshot: granted, tailnetPage: true, tailnetOn: true), .done)
    }
}
