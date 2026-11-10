// Everything that parses and holds markdown, with no drawing in it, lives in MarkdownCore;
// whoever imports MarkdownView gets it as before.
@_spi(MarkdownMath) @_exported import MarkdownCore
