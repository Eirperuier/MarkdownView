//
//  MathExtractionTests.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/9.
//

import Testing
@_spi(MarkdownMath) import MarkdownView

@MainActor
struct MathExtractionTests {
    struct MathExtractionTestConfiguration: Sendable {
        var plainText: String
        var extractedMath: [String]
    }
    
    @Test(
        arguments: [
            MathExtractionTestConfiguration(
                plainText: #"""
                **The Cauchy-Schwarz Inequality**
                $$\left( \sum_{k=1}^n a_k b_k \right)^2 \leq \left( \sum_{k=1}^n a_k^2 \right) \left( \sum_{k=1}^n b_k^2 \right)$$
                """#,
                extractedMath: [#"$$\left( \sum_{k=1}^n a_k b_k \right)^2 \leq \left( \sum_{k=1}^n a_k^2 \right) \left( \sum_{k=1}^n b_k^2 \right)$$"#]
            ),
            MathExtractionTestConfiguration(
                plainText: #"\( G_{\mu\nu} \): Einstein tensor (spacetime curvature)"#,
                extractedMath: [#"\( G_{\mu\nu} \)"#]
            ),
            MathExtractionTestConfiguration(
                plainText: #"\[ \hat{H}\psi = E\psi \quad \text{where} \quad \hat{H} = -\frac{\hbar^2}{2m}\nabla^2 + V(\mathbf{r}) \]"#,
                extractedMath: [#"\[ \hat{H}\psi = E\psi \quad \text{where} \quad \hat{H} = -\frac{\hbar^2}{2m}\nabla^2 + V(\mathbf{r}) \]"#]
            ),
            MathExtractionTestConfiguration(
                plainText: #"$$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$"#,
                extractedMath: [#"$$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$"#]
            ),
            MathExtractionTestConfiguration(
                plainText: #"$$\mathbf{A} = \begin{pmatrix} a_{11} & a_{12} & a_{13} \\ a_{21} & a_{22} & a_{23} \\ a_{31} & a_{32} & a_{33} \end{pmatrix}$$"#,
                extractedMath: [#"$$\mathbf{A} = \begin{pmatrix} a_{11} & a_{12} & a_{13} \\ a_{21} & a_{22} & a_{23} \\ a_{31} & a_{32} & a_{33} \end{pmatrix}$$"#]
            ),
            MathExtractionTestConfiguration(
                plainText: #"\[\]"#,
                extractedMath: []
            ),
            MathExtractionTestConfiguration(
                plainText: #"\(\)"#,
                extractedMath: []
            ),
        ]
    )
    func testMathExtractionCase(
        _ configuration: MathExtractionTestConfiguration
    ) async throws {
        let parser = MathParser(text: configuration.plainText)
        let extractedMath = parser.mathRepresentations
            .map(\.range)
            .map { String(configuration.plainText[$0]) }
        #expect(extractedMath == configuration.extractedMath)
    }
}
