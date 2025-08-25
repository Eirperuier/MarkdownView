//
//  MathBlockDirectiveRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import Foundation
import SwiftUI
#if canImport(LaTeXSwiftUI)
import LaTeXSwiftUI
#endif

struct MathBlockDirectiveRenderer: BlockDirectiveRenderer {
    func makeBody(configuration: Configuration) -> some View {
        if let identifier = UUID(uuidString: configuration.arguments[0].value) {
            DisplayMath(mathIdentifier: identifier)
        } else {
            EmptyView()
        }
    }
}

fileprivate struct DisplayMath: View {
    var mathIdentifier: UUID
    @Environment(\.markdownFontGroup.displayMath) private var font
    @Environment(\.markdownRendererConfiguration.math) private var math
    private var latexMath: String? {
        math.displayMathStorage?[mathIdentifier]
    }

    var body: some View {
        
        HStack {
            latex
        }
    }
    
    @ViewBuilder
    private var latex: some View {
        #if canImport(LaTeXSwiftUI)
        if let latexMath {
            LaTeX(latexMath)
                .font(font)
                .renderingStyle(.original)
                .ignoreStringFormatting()
                .blockMode(.blockText)
                .unencoded()
                .errorMode(.error)
                .processEscapes()
                .preload()
                
                //.frame(maxWidth: .infinity)
        }
        #else
        EmptyView()
        #endif
    }
}
