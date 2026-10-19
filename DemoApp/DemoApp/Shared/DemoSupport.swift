//
//  DemoSupport.swift
//  DemoApp
//
//  Where the demo keeps what it keeps.
//

import Foundation

extension URL {
    /// The demo's Application Support: the container's on iOS; on the Mac, which isn't
    /// sandboxed (it runs Floo Helper, FlooHelper.swift), a folder of its own in the user's.
    static var demoSupport: URL {
        #if targetEnvironment(macCatalyst)
        applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "DemoApp", directoryHint: .isDirectory)
        #else
        applicationSupportDirectory
        #endif
    }
}
