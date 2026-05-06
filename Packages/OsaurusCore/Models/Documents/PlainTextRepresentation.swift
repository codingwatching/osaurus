//
//  PlainTextRepresentation.swift
//  osaurus
//
//  Default representation for adapters that extract a single text string.
//  Every adapter has to publish *some* `StructuredRepresentation`; the
//  wrappers around `PDFKit` text extraction and `NSAttributedString` don't
//  preserve any format-native structure, so they emit this shape. The
//  real typed representations (`Workbook`, `WordDocument`, …) replace it
//  per-format as higher-fidelity adapters land.
//

import Foundation

public struct PlainTextRepresentation: StructuredRepresentation, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}
