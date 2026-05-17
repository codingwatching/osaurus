//
//  RichDocumentRepresentation.swift
//  osaurus
//

import Foundation

/// Safe source-format labels for rich text imports that still flow through
/// AppKit. The enum keeps the migration adapter honest: it can advertise
/// "DOCX text imported through NSAttributedString" without implying full
/// OOXML package fidelity.
public enum RichDocumentSourceFormat: String, Codable, Equatable, Sendable {
    case docx
    case doc
    case rtf
    case rtfd
    case html
    case unknown

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "docx": self = .docx
        case "doc": self = .doc
        case "rtf": self = .rtf
        case "rtfd": self = .rtfd
        case "html", "htm": self = .html
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .docx: return "Word document (DOCX)"
        case .doc: return "Word document (legacy DOC)"
        case .rtf: return "Rich Text Format"
        case .rtfd: return "Rich Text Format Directory"
        case .html: return "HTML document"
        case .unknown: return "Rich document"
        }
    }
}

/// A format-neutral block recovered from `NSAttributedString` paragraph
/// metadata. These blocks intentionally model only what AppKit exposes
/// safely; package-native tables, comments, tracked changes, and embedded
/// object graphs belong to the later high-fidelity Office lanes.
public struct RichDocumentBlock: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paragraph
        case heading
        case listItem
    }

    public let kind: Kind
    public let text: String
    public let textRange: DocumentTextRange
    public let sourceIndex: Int
    public let headingLevel: Int?
    public let listDepth: Int?
    public let anchorId: String

    public init(
        kind: Kind,
        text: String,
        textRange: DocumentTextRange,
        sourceIndex: Int,
        headingLevel: Int? = nil,
        listDepth: Int? = nil,
        anchorId: String
    ) {
        self.kind = kind
        self.text = text
        self.textRange = textRange
        self.sourceIndex = sourceIndex
        self.headingLevel = headingLevel
        self.listDepth = listDepth
        self.anchorId = anchorId
    }
}

/// Typed representation for the migration rich-document reader. The plain
/// `text` remains the compatibility contract, while `blocks` give callers a
/// conservative structure view when AppKit exposed one without extra Office
/// dependencies.
public struct RichDocumentRepresentation: StructuredRepresentation, Codable, Equatable, Sendable {
    public let sourceFormat: RichDocumentSourceFormat
    public let sourceLabel: String
    public let text: String
    public let blocks: [RichDocumentBlock]

    public init(
        sourceFormat: RichDocumentSourceFormat,
        sourceLabel: String,
        text: String,
        blocks: [RichDocumentBlock]
    ) {
        self.sourceFormat = sourceFormat
        self.sourceLabel = sourceLabel
        self.text = text
        self.blocks = blocks
    }
}
