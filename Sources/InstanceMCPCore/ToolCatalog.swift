import Foundation

/// Every local tool this daemon registers, in one place. `main.swift` serves this
/// list and `ProfileBoundaryTests` checks it, so a tool cannot be served without
/// also being classified (`ToolProfile.localToolClass`).
public enum ToolCatalog {
    public static func local(agentVersion: String) -> [any Tool] {
        [SysInfoTool(agentVersion: agentVersion), ExecTool(), ExecStartTool(), ExecPollTool(),
         ExecListTool(), ExecCancelTool(), ScreenshotTool(), UISnapshotTool(), UIActionTool(), MouseTool(), KeyTool(), OsascriptTool()]
    }
}
