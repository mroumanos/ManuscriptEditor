// LetterSectionView.swift
//
// Editor for a LETTER section — a text box that also carries a letterhead
// and a signature.
//
// The cover letter used to be a fixed part of every manuscript with a pane
// of its own; it is a section now (`SectionKind.letter`), so this is what a
// section pane shows when the section is a letter — the same way a question
// series gets `QuestionSeriesView`.  Added, removed, renamed and reordered
// like any other section.
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
// A VSplitView so the letterhead/signature form and the body editor are
// independently resizable — the body is usually much longer.
//
//   TOP    — three letterhead slots (left / center / right), each an image
//            or free text, laid out like a real letterhead; the drawn
//            signature.
//   BOTTOM — the body, in the ordinary editor.  "/" offers ⟦Date⟧ and
//            ⟦Signature⟧ as well as the usual references.
//
// Every change goes through `store.updateSection`, like any section's.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LetterSectionView

struct LetterSectionView: View {
    @Environment(ManuscriptStore.self) private var store

    let sectionID: UUID
    var versionRef: VersionRef = .source

    /// Working copies, so a keystroke doesn't round-trip through the store
    /// on every render.
    @State private var details = LetterDetails()
    @State private var body_ = RichText()
    @State private var showSignaturePad = false

    private var section: ManuscriptSection? {
        store.section(sectionID, ref: versionRef)
    }

    var body: some View {
        if let section, section.active {
            VSplitView {
                metadataForm
                    .frame(minHeight: 260, idealHeight: 320)
                bodyEditor(section)
                    .frame(minHeight: 200)
            }
            .onAppear { load(section) }
            .onChange(of: sectionID) { _, _ in if let s = self.section { load(s) } }
            // Sync from external changes (undo, a cut switch).
            .onChange(of: section.letter) { _, new in
                if let new, new != details { details = new }
            }
            .onChange(of: section.content) { _, new in
                if new != body_ { body_ = new }
            }
            .onChange(of: details) { _, new in
                guard var edited = self.section, edited.letter != new else { return }
                edited.letter = new
                store.updateSection(edited, ref: versionRef)
            }
            .onChange(of: body_) { _, new in
                guard var edited = self.section, edited.content != new else { return }
                edited.content = new
                store.updateSection(edited, ref: versionRef)
            }
        } else {
            ContentUnavailableView("Deactivated in this journal", systemImage: "moon.zzz",
                                   description: Text("Its text is kept. Activate it from the pane header."))
        }
    }

    private func load(_ section: ManuscriptSection) {
        details = section.letter ?? LetterDetails()
        body_ = section.content
    }

    // MARK: – Top: letterhead + signature form

    private var metadataForm: some View {
        ScrollView {
            Form {
                Section("Header") {
                    HStack(alignment: .top, spacing: 0) {
                        HeaderSlotEditor(title: "Left", alignment: .leading, slot: $details.headerLeft)
                        Divider().padding(.horizontal, 10)
                        HeaderSlotEditor(title: "Center", alignment: .center, slot: $details.headerCenter)
                        Divider().padding(.horizontal, 10)
                        HeaderSlotEditor(title: "Right", alignment: .trailing, slot: $details.headerRight)
                    }
                    Text("Each slot holds an image or free text — laid out left, centered, and right across the top of the letter, like a letterhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Signature") {
                    if let data = details.signatureImageData, let image = NSImage(data: data) {
                        HStack(spacing: 12) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 56)
                                .padding(6)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            Spacer()
                            Button("Redraw…") { showSignaturePad = true }
                            Button {
                                details.signatureImageData = nil
                            } label: {
                                Text("Remove").foregroundStyle(.red)
                            }
                        }
                    } else {
                        Button {
                            showSignaturePad = true
                        } label: {
                            Label("Draw Signature…", systemImage: "signature")
                        }
                    }
                    Text("Type \"/\" in the letter body to place the signature (or today's date) — it renders in the preview and exports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSignaturePad) {
            SignaturePadSheet(isPresented: $showSignaturePad) { image in
                details.signatureImageData = image.pngData(maxDimension: 800)
            }
        }
    }

    // MARK: – Bottom: letter body

    private func bodyEditor(_ section: ManuscriptSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text("\(WordCountService.count(body_.plain)) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            Divider()
            RichEditor(value: $body_, placeholder: "Dear Editor,…",
                       versionRef: versionRef, letterMode: true,
                       letterSignatureDrawn: details.signatureImageData != nil,
                       formatItem: .section(section.id))
        }
    }
}

// MARK: - LetterToken

/// The letter body's live references, inserted by "/": stable marker text in
/// the prose (carrying a letter:// link in the editor) that preview and
/// export resolve — ⟦Date⟧ → today, ⟦Signature⟧ → the drawn signature.
enum LetterToken: String, CaseIterable {
    case date, signature

    var marker: String {
        switch self {
        case .date:      return "⟦Date⟧"
        case .signature: return "⟦Signature⟧"
        }
    }

    var url: URL { URL(string: "letter://\(rawValue)")! }
}

// MARK: - HeaderSlotEditor

/// Edits one letterhead slot: an image well (add/replace/remove) above a
/// small freeform text area, previewed with the slot's real alignment.
private struct HeaderSlotEditor: View {
    let title: String
    let alignment: HorizontalAlignment
    @Binding var slot: LetterHeaderSlot

    private var textAlignment: NSTextAlignment {
        switch alignment {
        case .center:   return .center
        case .trailing: return .right
        default:        return .left
        }
    }

    /// Which of the two a slot is holding.  Kept in the view because an
    /// empty slot has to sit in one mode or the other before anything is in
    /// it — the model only records what it ended up with.
    private enum Mode: String, CaseIterable, Identifiable {
        case text, image
        var id: String { rawValue }
        var label: String { self == .text ? "Text" : "Image" }
    }
    @State private var mode: Mode = .text

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                // One slot, one thing in it: the picker chooses WHICH, and
                // only that control takes the space.  (Showing an image well
                // above a text well made every text slot sit lower than it
                // prints.)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: mode) { _, new in
                    // Switching clears the other side, so the slot always
                    // holds exactly what the picker says.
                    if new == .text { slot.setImage(nil) } else { slot.setText("") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            switch mode {
            case .image:
                if let data = slot.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 56)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                slot.setImage(nil)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .background(Circle().fill(.background))
                            }
                            .buttonStyle(.plain)
                            .help("Remove image")
                            .offset(x: 8, y: -8)
                        }
                        .frame(maxWidth: .infinity, alignment: swiftUIAlignment)
                } else {
                    Button {
                        chooseImage()
                    } label: {
                        Label("Add Image…", systemImage: "photo.badge.plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            case .text:
                PlainTextEditor(text: $slot.editableText, alignment: textAlignment)
                    .frame(minHeight: 54, maxHeight: 72)
                    .overlay(alignment: .topLeading) {
                        if slot.text.isEmpty {
                            Text("Text…")
                                .font(.callout)
                                .foregroundStyle(.quaternary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { mode = slot.isImage ? .image : .text }
    }

    private var swiftUIAlignment: Alignment {
        switch alignment {
        case .center:   return .center
        case .trailing: return .trailing
        default:        return .leading
        }
    }

    /// Picks an image file and stores it in the slot.  SVGs keep their raw
    /// vector bytes (they scale cleanly in previews and exports); raster
    /// images are downscaled — logos embed in manuscript.json, so large
    /// photos are capped at 1000 px.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "svg",
           let data = try? Data(contentsOf: url), NSImage(data: data) != nil {
            slot.setImage(data)
        } else if let image = NSImage(contentsOf: url) {
            slot.setImage(image.pngData(maxDimension: 1000))
        }
    }
}

// MARK: - SignaturePadSheet

/// A drawable signature pad: freehand strokes on a white pad, with Reset.
/// Saving renders the strokes to a PNG (black ink, 2× scale) via ImageRenderer.
private struct SignaturePadSheet: View {
    @Binding var isPresented: Bool
    let onSave: (NSImage) -> Void

    @State private var strokes: [[CGPoint]] = []
    private let padSize = CGSize(width: 440, height: 160)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Draw Signature").font(.headline)

            SignatureCanvas(strokes: $strokes)
                .frame(width: padSize.width, height: padSize.height)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack {
                Button("Reset") { strokes = [] }
                    .disabled(strokes.isEmpty)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Crop to the ink's bounding box — saving the whole pad
                    // left blank margins around the strokes, so the signature
                    // floated wherever it was drawn instead of sitting flush
                    // left where it's placed.
                    let points = strokes.flatMap { $0 }
                    guard let firstX = points.map(\.x).min(),
                          let firstY = points.map(\.y).min(),
                          let lastX = points.map(\.x).max(),
                          let lastY = points.map(\.y).max() else { return }
                    let box = CGRect(x: firstX, y: firstY,
                                     width: max(lastX - firstX, 1),
                                     height: max(lastY - firstY, 1))
                        .insetBy(dx: -6, dy: -6)
                    let shifted = strokes.map { stroke in
                        stroke.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
                    }
                    let renderer = ImageRenderer(content:
                        SignatureShape(strokes: shifted)
                            .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: box.width, height: box.height))
                    renderer.scale = 2
                    if let image = renderer.nsImage { onSave(image) }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(24)
    }
}

/// The strokes as one Path (each stroke a connected polyline).
private struct SignatureShape: Shape {
    let strokes: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for stroke in strokes where !stroke.isEmpty {
            path.move(to: stroke[0])
            for point in stroke.dropFirst() { path.addLine(to: point) }
        }
        return path
    }
}

/// The live drawing surface: black ink following the pointer.
private struct SignatureCanvas: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var body: some View {
        SignatureShape(strokes: strokes + [current])
            .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { current.append($0.location) }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                    }
            )
    }
}

// MARK: - NSImage transparent-margin trim

extension NSImage {
    /// The image cropped to its non-transparent pixels — heals signatures
    /// saved before ink-cropping existed, whose blank pad margins made the
    /// ink float toward the center instead of sitting flush left.
    func trimmedTransparentMargins() -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return self }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return self }
        let alpha = data.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        // Fully opaque (no alpha channel in practice) or fully empty, or
        // already tight: nothing to trim.
        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                                                   width: maxX - minX + 1,
                                                   height: maxY - minY + 1))
        else { return self }
        // Keep the point-size scale of the original (2× pad renders).
        let scaleX = size.width / CGFloat(width)
        let scaleY = size.height / CGFloat(height)
        return NSImage(cgImage: cropped,
                       size: NSSize(width: CGFloat(cropped.width) * scaleX,
                                    height: CGFloat(cropped.height) * scaleY))
    }
}

// MARK: - NSImage → PNG helper

extension NSImage {
    /// PNG data, downscaled so the longest side is at most `maxDimension`
    /// (letterhead logos live inside manuscript.json — keep them small).
    func pngData(maxDimension: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let scale = min(1, maxDimension / max(pixelSize.width, pixelSize.height))
        if scale >= 1 {
            return rep.representation(using: .png, properties: [:])
        }
        let target = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return scaled.representation(using: .png, properties: [:])
    }
}
