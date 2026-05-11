//
//  MarkdownImageRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/13.
//

import SwiftUI

/// A type that renders images.
///
/// Think of this type as a SwiftUI View wrapper.
///
/// Don't directly access view dependencies (e.g. `@Environment`), use a separate view instead.
@preconcurrency
@MainActor
public protocol MarkdownImageRenderer {
    /// A type that represents the image.
    associatedtype Body: View
    
    /// Creates a view that represents the image.
    /// - parameter configuration: The properties of a markdown image.
    @preconcurrency
    @MainActor
    @ViewBuilder
    func makeBody(configuration: Configuration) -> Body
    
    /// The properties of a markdown image.
    typealias Configuration = MarkdownImageRendererConfiguration
}

/// The properties of a markdown image.
public struct MarkdownImageRendererConfiguration: Sendable {
    /// The source url of an image.
    public var url: URL
    /// The alternative text of an image.
    public var alternativeText: String?
}

// MARK: - Table Image Rendering

public struct AnyMarkdownTableImageRenderer: Sendable {
    private let _makeBody: @MainActor @Sendable (MarkdownImageRendererConfiguration) -> AnyView

    init(_ build: @escaping @MainActor @Sendable (MarkdownImageRendererConfiguration) -> AnyView) {
        self._makeBody = build
    }

    @MainActor
    func makeBody(configuration: MarkdownImageRendererConfiguration) -> AnyView {
        _makeBody(configuration)
    }
}

struct MarkdownTableImageRendererKey: EnvironmentKey {
    static let defaultValue: AnyMarkdownTableImageRenderer? = nil
}

struct MarkdownImageIsInTableCellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownTableImageRenderer: AnyMarkdownTableImageRenderer? {
        get { self[MarkdownTableImageRendererKey.self] }
        set { self[MarkdownTableImageRendererKey.self] = newValue }
    }

    var markdownImageIsInTableCell: Bool {
        get { self[MarkdownImageIsInTableCellKey.self] }
        set { self[MarkdownImageIsInTableCellKey.self] = newValue }
    }
}

// MARK: - Type Erasure

/// A type-erasure for type conforms to `MarkdownImageRenderer`.
public struct AnyMarkdownImageRenderer: MarkdownImageRenderer {
    public typealias Body = AnyView
    
    private let _makeBody: (Configuration) -> Body
    
    public init<D: MarkdownImageRenderer>(erasing renderer: D) {
        _makeBody = {
            renderer
                .makeBody(configuration: $0)
                .erasedToAnyView()
        }
    }
    
    public init<D: MarkdownImageRenderer>(_ renderer: D) {
        _makeBody = {
            renderer
                .makeBody(configuration: $0)
                .erasedToAnyView()
        }
    }
    
    public func makeBody(configuration: Configuration) -> AnyView {
        _makeBody(configuration)
    }
}
