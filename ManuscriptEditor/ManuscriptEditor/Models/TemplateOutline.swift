// TemplateOutline.swift
//
// The export outline as a template's `export.json` says it — the file a
// person reads and edits, as distinct from `ExportConfig`, the outline a
// manuscript holds and the exporter runs.
//
//   documents          each a file of one type (docx, pdf, rtf, latex)
//   document sections  each with its own margin, line numbers, page numbers
//                      and columns — a new document section is a new page
//   items              named by TITLE: a structure section's title, or one of
//                      the fixed components' names ("Title Page", "Authors",
//                      "Abstract", "Keywords", "References", "Tables",
//                      "Figures", "Cover Letter")
//
// Typography is a component's, never a document's.  A manuscript section's
// is the STRUCTURE's (`format` on its entry): an outline may print a section
// twice, and two places for one setting is a conflict waiting to happen.  A
// fixed component's sits on its item.  No GUIDs: titles are the link, and
// the structure's derived ids are computed on read.
//
// Anything else an item carries — a heading style, a citation style, the
// byline's delimiters — passes through under `settings`, as the item's own
// fields.  So a template saved from the app keeps every option, and a file
// written by hand needs none of them.

import Foundation

struct TemplateOutline: Codable, Equatable, Sendable {

    struct Typography: Codable, Equatable, Sendable {
        var fontFamily: String?
        var fontSize: Double?
        var lineSpacing: Double?

        init(_ format: ExportDocumentFormat) {
            fontFamily = format.fontFamily.rawValue
            fontSize = format.fontSize
            lineSpacing = format.lineSpacing
        }

        /// The typography over a base format — what's unsaid inherits.
        func applied(to base: ExportDocumentFormat) -> ExportDocumentFormat {
            var out = base
            if let fontFamily, let family = ExportFontFamily(rawValue: fontFamily) { out.fontFamily = family }
            if let fontSize { out.fontSize = fontSize }
            if let lineSpacing { out.lineSpacing = lineSpacing }
            return out
        }
    }

    struct Item: Codable, Equatable, Sendable {
        /// "component" — the one type an item has today.
        var type: String = "component"
        var title: String
        /// A fixed component's typography (a manuscript section's is the
        /// structure's).
        var format: Typography?
        /// The item's other options, as the app's own fields.
        var settings: JSONValue?
    }

    struct DocumentSection: Codable, Equatable, Sendable {
        var margin: Double?
        var lineNumbers: Bool?
        var pageNumbers: Bool?
        var columns: Int?
        var items: [Item]
    }

    struct Document: Codable, Equatable, Sendable {
        var name: String
        var type: String
        var sections: [DocumentSection]
    }

    var documents: [Document]

    // MARK: - The fixed components, by name

    static let componentTitles: [ExportItem.ItemType: String] = [
        .titlePage: "Title Page", .authors: "Authors", .abstract: "Abstract", .keywords: "Keywords",
        .references: "References", .tables: "Tables", .figures: "Figures", .coverLetter: "Cover Letter",
    ]

    static func fixedType(named title: String) -> ExportItem.ItemType? {
        componentTitles.first { $0.value.lowercased() == title.lowercased() }?.key
    }

    // MARK: - From the app's outline

    /// The outline as a file says it.  Items at sections the structure does
    /// not have are dropped: there is no title to name them by.
    static func from(_ config: ExportConfig, structure: JournalStructure) -> TemplateOutline {
        let titleByUID = Dictionary(structure.sections.map { ($0.uid, $0.title) },
                                    uniquingKeysWith: { first, _ in first })
        return TemplateOutline(documents: config.documents.map { doc in
            var sections: [DocumentSection] = []
            var current = DocumentSection(
                margin: doc.format.marginInches, lineNumbers: doc.format.lineNumbers,
                pageNumbers: doc.format.pageNumbers, columns: doc.format.twoColumn ? 2 : 1, items: [])
            for item in doc.items {
                if item.type == .pageBreak {
                    // A break before anything printed is the document's own
                    // first page; one after starts the next section, whose
                    // unset geometry inherits.
                    if current.items.isEmpty && sections.isEmpty {
                        if let m = item.sectionMarginInches { current.margin = m }
                        if let l = item.sectionLineNumbers { current.lineNumbers = l }
                        if let p = item.sectionPageNumbers { current.pageNumbers = p }
                        if let two = item.sectionTwoColumn { current.columns = two ? 2 : 1 }
                    } else {
                        sections.append(current)
                        current = DocumentSection(
                            margin: item.sectionMarginInches, lineNumbers: item.sectionLineNumbers,
                            pageNumbers: item.sectionPageNumbers,
                            columns: item.sectionTwoColumn.map { $0 ? 2 : 1 }, items: [])
                    }
                    continue
                }
                let title: String
                var format: Typography?
                if item.type == .manuscriptSection {
                    guard let id = item.sectionID, let t = titleByUID[id] else { continue }
                    title = t
                } else {
                    title = componentTitles[item.type] ?? item.type.rawValue
                    // What the component prints in — its own, else the
                    // document's where that is not the default.
                    let effective = item.format ?? doc.format
                    if item.format != nil || Typography(effective) != Typography(ExportDocumentFormat()) {
                        format = Typography(effective)
                    }
                }
                current.items.append(Item(title: title, format: format, settings: settings(of: item)))
            }
            sections.append(current)
            return Document(name: doc.name, type: doc.fileType.rawValue, sections: sections)
        })
    }

    /// What an item carries besides what the outline says in its own words.
    private static let expressed: Set<String> = [
        "id", "kind", "type", "sectionID", "format",
        "sectionMarginInches", "sectionTwoColumn", "sectionLineNumbers", "sectionPageNumbers",
    ]

    private static func settings(of item: ExportItem) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(item),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in expressed { object[key] = nil }
        guard !object.isEmpty else { return nil }
        return JSONValue(object)
    }

    // MARK: - To the app's outline

    /// The app's outline, pointed at this structure's sections.  Ids are
    /// derived from the profile's, so every read gives the same outline.
    func exportConfig(structure: JournalStructure, profileID: UUID) -> ExportConfig {
        let entryByTitle = Dictionary(structure.sections.map { ($0.title.lowercased(), $0) },
                                      uniquingKeysWith: { first, _ in first })
        var out = ExportConfig(documents: [])
        for (d, doc) in documents.enumerated() {
            var base = ExportDocumentFormat()
            if let first = doc.sections.first {
                if let m = first.margin { base.marginInches = m }
                if let l = first.lineNumbers { base.lineNumbers = l }
                if let p = first.pageNumbers { base.pageNumbers = p }
                if let c = first.columns { base.twoColumn = c >= 2 }
            }
            var items: [ExportItem] = []
            for (s, section) in doc.sections.enumerated() {
                // Every document leads with a break (the outline the app
                // builds does), and each further section is one.
                var brk = ExportItem(id: Self.stableID("export-break:\(profileID):\(d):\(s)"), type: .pageBreak)
                if s > 0 {
                    brk.sectionMarginInches = section.margin
                    brk.sectionLineNumbers = section.lineNumbers
                    brk.sectionPageNumbers = section.pageNumbers
                    brk.sectionTwoColumn = section.columns.map { $0 >= 2 }
                }
                items.append(brk)
                for (i, item) in section.items.enumerated() {
                    let id = Self.stableID("export-item:\(profileID):\(d):\(s):\(i)")
                    var made: ExportItem
                    if let entry = entryByTitle[item.title.lowercased()], entry.subject == .section || entry.subject == .abstract {
                        if entry.subject == .abstract {
                            made = Self.item(type: .abstract, id: id, settings: item.settings)
                        } else {
                            made = Self.item(type: .manuscriptSection, id: id, settings: item.settings)
                            made.sectionID = entry.uid
                            made.format = entry.format
                        }
                    } else if let fixed = Self.fixedType(named: item.title) {
                        made = Self.item(type: fixed, id: id, settings: item.settings)
                        if let typography = item.format {
                            made.format = typography.applied(to: base)
                        }
                    } else {
                        continue    // no section of that title — nothing to print
                    }
                    items.append(made)
                }
            }
            out.documents.append(ExportDocument(
                id: Self.stableID("export-doc:\(profileID):\(d)"), name: doc.name,
                fileType: ExportFileType(rawValue: doc.type) ?? .docx, format: base, items: items))
        }
        return out
    }

    /// An item of a type, with its settings read back as its own fields.
    private static func item(type: ExportItem.ItemType, id: UUID, settings: JSONValue?) -> ExportItem {
        var object: [String: Any] = settings?.object ?? [:]
        object["id"] = id.uuidString
        object["type"] = type.rawValue
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? decoder.decode(ExportItem.self, from: data) {
            return decoded
        }
        return ExportItem(id: id, type: type)
    }

    static func stableID(_ seed: String) -> UUID {
        StructureSection.derivedID(title: seed)
    }
}

/// Any JSON, for the options an outline item passes through.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(_ any: Any) {
        switch any {
        case let dict as [String: Any]: self = .object(dict.mapValues(JSONValue.init))
        case let array as [Any]:        self = .array(array.map(JSONValue.init))
        case let string as String:      self = .string(string)
        case let bool as Bool:          self = .bool(bool)
        case let number as NSNumber:    self = .number(number.doubleValue)
        default:                        self = .null
        }
    }

    /// Back to Foundation's shape.
    var any: Any {
        switch self {
        case .object(let o): return o.mapValues(\.any)
        case .array(let a):  return a.map(\.any)
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b):   return b
        case .null:          return NSNull()
        }
    }
    var object: [String: Any]? { if case .object(let o) = self { return o.mapValues(\.any) }; return nil }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded() && abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        }
    }
}
