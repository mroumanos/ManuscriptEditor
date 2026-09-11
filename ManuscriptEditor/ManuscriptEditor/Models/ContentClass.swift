// ContentClass.swift
//
// WHICH CONTENT IS WHOSE — the one distinction every feature keeps running into
// ─────────────────────────────────────────────────────────────────────────────
// Everything in a manuscript is one of two things:
//
//   CORE     The manuscript's own: title, authors, keywords, figures, tables,
//            bibliography, and the letter to the editor.  A venue has an
//            opinion about how they are SET (typography, in the outline),
//            never about what they say.  Carried whole into every cut; never
//            templated, never adapted, never described by a template; a fixed
//            row above the sidebar's rule.
//
//   JOURNAL  A cut's prose, which a venue shapes: the abstract and every body
//            section.  Templated when a journal is added (the venue's
//            boilerplate, tokens live), migrated on fast-forward where the
//            upstream has text, adapted with Assist, described in a
//            template's structure; below the rule.
//
// The distinction used to be re-derived at every site — `sectionKind ==
// .letter` here, `key == "abstract"` there — and each site got it slightly
// differently, which is how the abstract was carried like a title, the letter
// was templated like a section, and a template's letter entry became a
// section in every manuscript.  This file answers it once, for every model
// that carries content: a manuscript's section, a template's structure entry,
// an outline item, a sidebar row.  A call site that needs to know asks here;
// one that tests a kind or a title directly is a bug waiting for the next
// exception.
//
// See MasterContext/02-domain-model.md, "Core content and journal content".

import Foundation

enum ContentClass: Sendable {
    case core, journal
}

// MARK: - The core parts

/// The core parts, in the order every sidebar lists them.
enum CorePart: CaseIterable, Sendable {
    case title, authors, keywords, figures, tables, bibliography, letter

    var label: String {
        switch self {
        case .title:        return "Title"
        case .authors:      return "Authors"
        case .keywords:     return "Keywords"
        case .figures:      return "Figures"
        case .tables:       return "Tables"
        case .bibliography: return "Bibliography"
        case .letter:       return "Letter to the Editor"
        }
    }

    var systemImage: String {
        switch self {
        case .title:        return "textformat"
        case .authors:      return "person.2"
        case .keywords:     return "tag"
        case .figures:      return "photo.on.rectangle.angled"
        case .tables:       return "tablecells"
        case .bibliography: return "books.vertical"
        case .letter:       return "envelope"
        }
    }

    /// How a template's text can refer to the part — a token, or the kind of
    /// reference the editor inserts.  The letter cannot be referred to: it is
    /// the author's, and a template has nothing to say about it.
    var reference: String? {
        switch self {
        case .title:        return "[[title]]"
        case .authors:      return "[[authors.names]]"
        case .keywords:     return "[[keywords]]"
        case .figures:      return "a figure reference"
        case .tables:       return "a table reference"
        case .bibliography: return "a citation"
        case .letter:       return nil
        }
    }

    var sidebarItem: SidebarItem {
        switch self {
        case .title:        return .title
        case .authors:      return .authors
        case .keywords:     return .keywords
        case .figures:      return .figures
        case .tables:       return .tables
        case .bibliography: return .bibliography
        case .letter:       return .letterToEditor
        }
    }
}

// MARK: - A manuscript's sections

extension SectionKind {
    /// The letter is the one core SECTION — stored as a section, owned like a
    /// title.  Everything else a section can be is a cut's prose.
    var contentClass: ContentClass { self == .letter ? .core : .journal }

    /// The kinds Add Section offers: journal content only.  The letter has a
    /// pane of its own.
    static var addable: [SectionKind] { allCases.filter { $0.contentClass == .journal } }
}

extension ManuscriptSection {
    var contentClass: ContentClass { sectionKind.contentClass }
    var isCore: Bool { contentClass == .core }
    var isJournalContent: Bool { contentClass == .journal }
}

extension Manuscript {
    /// The manuscript's letter, if its pane has ever been opened — the one
    /// core section, first by order.
    var letterSection: ManuscriptSection? {
        sections.sorted { $0.order < $1.order }.first { $0.isCore }
    }

    /// The prose a venue shapes: every section but the letter.
    var journalSections: [ManuscriptSection] {
        sections.filter(\.isJournalContent)
    }
}

// MARK: - A template's structure

extension StructureSection {
    /// What a template entry is about.
    enum Subject: Sendable {
        /// The abstract FIELD — its format, notes and boilerplate.  Never a
        /// section of its own.
        case abstract
        /// A body section the venue names, created in every manuscript that
        /// adds the journal.
        case section
        /// Core content — a letter entry, which templates could carry for a
        /// while.  Ignored wherever entries are read: it is the author's.
        case core
    }

    var subject: Subject {
        if kind == .letter { return .core }
        return key == "abstract" ? .abstract : .section
    }

    var describesJournalContent: Bool { subject != .core }
}

extension JournalStructure {
    /// The entries that describe journal content — what a manuscript, the
    /// checks, the prompt and the outline read.
    var journalEntries: [StructureSection] { sections.filter(\.describesJournalContent) }
    /// The entries that become sections.
    var sectionEntries: [StructureSection] { sections.filter { $0.subject == .section } }
    /// The venue's say about the abstract, if it has one.
    var abstractEntry: StructureSection? { sections.first { $0.subject == .abstract } }
}

// MARK: - An outline's items

extension ExportItem.Kind {
    /// nil for a page break, which is layout rather than content.
    var contentClass: ContentClass? {
        switch self {
        case .titlePage, .authors, .keywords, .figures, .tables, .references, .coverLetter:
            return .core
        case .abstract, .section:
            return .journal
        case .pageBreak:
            return nil
        }
    }

    /// The core parts as outline items, in outline order — what Add Item
    /// lists under Components.
    static let coreKinds: [ExportItem.Kind] =
        [.titlePage, .authors, .keywords, .figures, .tables, .references, .coverLetter]
}

// MARK: - The sidebar

extension SidebarItem {
    /// nil for rows that are not content.
    var contentClass: ContentClass? {
        switch self {
        case .title, .authors, .keywords, .figures, .tables, .bibliography, .letterToEditor:
            return .core
        case .abstract, .section:
            return .journal
        default:
            return nil
        }
    }
}
