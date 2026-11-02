//
//  FlooStepPanel.swift
//  DemoApp
//
//  A step an agent hands you in the browser, done in a window of this app: on the Mac
//  whose browser engine has the step's page, 我来做 opens a small window showing just that
//  page, live — the agent's own page, in your own logins — with 做完了 and 跳过 under it
//  (floo's docs/interaction.md §4.1 `step`, its `tab`). The step ends there, on the card,
//  or when the agent's script ends it, and the page goes back to the agent either way.
//  Closing the window is 跳过.
//
//  The window is AppKit, and this is a Mac Catalyst app, which can't link AppKit: it's
//  floo-browser's FlooEnginePanel, built as a plug-in bundle (embed-panel.sh) and loaded
//  here at runtime, spoken to by selector with Foundation objects. The page is the engine's,
//  claimed over its XPC service, which admits this app by its signing identifier,
//  `dev.floo.app` (the Mac build signs it so).
//

#if targetEnvironment(macCatalyst)
import Foundation

enum FlooStepPanel {
    /// The plug-in's principal class, made once; nil when the app wasn't built with it.
    @MainActor private static let plugin: NSObject? = {
        guard let url = Bundle.main.builtInPlugInsURL?.appending(path: "FlooEnginePanel.bundle"),
              let bundle = Bundle(url: url)
        else { return nil }
        do { try bundle.loadAndReturnError() } catch {
            NSLog("FlooEnginePanel didn't load: \(error)")
            return nil
        }
        return (bundle.principalClass as? NSObject.Type)?.init()
    }()

    /// Whether this app can show a step's page in a window of its own.
    @MainActor static var available: Bool { plugin != nil }

    /// Opens the window for `ask`, showing engine page `tab`, or brings it forward if it's
    /// open. `ended` hears your answer given in the window: `completed` or `skipped`.
    /// False when it can't be shown here.
    @MainActor static func open(
        ask: String, tab: UInt64, title: String, instruction: String, ended: @escaping (String) -> Void
    ) -> Bool {
        let selector = NSSelectorFromString("openStep:onEnd:")
        guard let plugin, plugin.responds(to: selector) else { return false }
        let step: NSDictionary = ["ask": ask, "tab": NSNumber(value: tab), "title": title, "instruction": instruction]
        let block: @convention(block) (NSString) -> Void = { ended($0 as String) }
        _ = plugin.perform(selector, with: step, with: block as AnyObject)
        return true
    }

    /// The step `ask` ended elsewhere: its window goes, unanswered, and the page goes back
    /// to the agent.
    @MainActor static func close(ask: String) {
        let selector = NSSelectorFromString("closeStep:")
        guard let plugin, plugin.responds(to: selector) else { return }
        _ = plugin.perform(selector, with: ask as NSString)
    }

    #if DEBUG
        /// For a test (FlooControl's `/panel`): the windows open, `[{ask, window, page}]`.
        @MainActor static var opened: [[String: Any]] {
            let selector = NSSelectorFromString("openSteps")
            guard let plugin, plugin.responds(to: selector) else { return [] }
            return plugin.perform(selector)?.takeUnretainedValue() as? [[String: Any]] ?? []
        }

        /// For a test: a click, typing or the close button in the window of `input["ask"]`, as
        /// AppKit events sent to it. False: no such window.
        @MainActor static func drive(_ input: [String: Any]) -> Bool {
            let selector = NSSelectorFromString("driveStep:")
            guard let plugin, plugin.responds(to: selector) else { return false }
            return (plugin.perform(selector, with: input as NSDictionary)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }
    #endif
}
#endif
