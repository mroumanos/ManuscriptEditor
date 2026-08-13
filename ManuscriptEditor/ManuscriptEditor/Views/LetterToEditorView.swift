// LetterToEditorView.swift
//
// Editor for the manuscript's cover letter (letter to the editor).
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
// The view uses a VSplitView so the header/signature form and the body editor
// are independently resizable — useful because the body is usually much longer.
//
// TOP HALF — Letterhead + signature:
//   • Three header slots (left / center / right), each an optional image
//     (logo, letterhead art) above freeform text — like a real letterhead
//   • Signature block (plain text, monospaced font)
//
// BOTTOM HALF — Body TextEditor:
//   • Main letter text: why this journal, study novelty, conflict of interest, etc.
//
// PREVIEW PANEL
// ─────────────────────────────────────────────────────────────────────────────
// A "Preview" toggle shows a read-only approximation of the finished letter,
// assembled from header + body + signature.  This lets authors check the
// overall look before submitting.
//
// AUTO-SAVE
// ─────────────────────────────────────────────────────────────────────────────
// Any draft change calls `store.updateLetterToEditor(_:)` via `onChange`,
// which routes through the `touch(_:)` helper in `ManuscriptStore` to bump
// `updatedAt` and persist to disk.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LetterToEditorView

/// Full editor for the manuscript's cover letter.
struct LetterToEditorView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// Mutable working copy to avoid writing to the store on every render.
    @State private var draft: LetterToEditor = .empty()
    @State private var showPreview = false
    @State private var showSignaturePad = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // Preview rides BESIDE the input (live, same window), never
            // replacing it — edits reflect immediately on the right.
            if showPreview {
                HSplitView {
                    editorPanel
                        .frame(minWidth: 380)
                    previewPanel
                        .frame(minWidth: 320)
                }
            } else {
                editorPanel
            }
        }
        .onAppear { syncDraft() }
        // Sync from external changes (e.g. undo, cut switch).
        .onChange(of: store.manuscript(for: versionRef)?.letterToEditor) { _, _ in syncDraft() }
        // Auto-save — guarded so external syncs don't echo back into the store.
        .onChange(of: draft) { _, new in
            guard new != store.manuscript(for: versionRef)?.letterToEditor else { return }
            store.updateLetterToEditor(new, ref: versionRef)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Spacer()
            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "eye")
            }
            .toggleStyle(.button)
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Editor panel

    private var editorPanel: some View {
        VSplitView {
            metadataForm
                .frame(minHeight: 260, idealHeight: 320)
            bodyEditor
                .frame(minHeight: 200)
        }
    }

    // MARK: – Top: letterhead + signature form

    private var metadataForm: some View {
        ScrollView {
            Form {
                Section("Header") {
                    HStack(alignment: .top, spacing: 0) {
                        HeaderSlotEditor(title: "Left", alignment: .leading, slot: $draft.headerLeft)
                        Divider().padding(.horizontal, 10)
                        HeaderSlotEditor(title: "Center", alignment: .center, slot: $draft.headerCenter)
                        Divider().padding(.horizontal, 10)
                        HeaderSlotEditor(title: "Right", alignment: .trailing, slot: $draft.headerRight)
                    }
                    Text("Each slot holds an optional image and free text — laid out left, centered, and right across the top of the letter, like a letterhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Signature") {
                    if let data = draft.signatureImageData, let image = NSImage(data: data) {
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
                                draft.signatureImageData = nil
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
                draft.signatureImageData = image.pngData(maxDimension: 800)
            }
        }
    }

    // MARK: – Bottom: letter body

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text("\(WordCountService.count(draft.body.plain)) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            Divider()
            RichEditor(value: $draft.body, placeholder: "Dear Editor,…",
                       versionRef: versionRef, letterMode: true)
        }
    }

    // MARK: - Preview panel

    /// Read-only assembled preview of the full letter.
    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if draft.hasHeader {
                    HStack(alignment: .top, spacing: 16) {
                        HeaderSlotPreview(slot: draft.headerLeft, alignment: .leading)
                        HeaderSlotPreview(slot: draft.headerCenter, alignment: .center)
                        HeaderSlotPreview(slot: draft.headerRight, alignment: .trailing)
                    }
                    .padding(.bottom, 8)

                    Divider()
                }

                // Body — the ⟦Date⟧/⟦Signature⟧ tokens resolve here just
                // like on export: today's date and the drawn signature.
                if draft.body.isEmpty {
                    Text("(letter body is empty)")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    let resolved = draft.body.plain.replacingOccurrences(
                        of: LetterToken.date.marker,
                        with: Date().formatted(date: .long, time: .omitted))
                    let parts = resolved.components(separatedBy: LetterToken.signature.marker)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { signaturePreviewImage }
                        if !part.isEmpty {
                            Text(part).lineSpacing(4)
                        }
                    }
                }

                // No token placed: the drawn signature still closes the letter.
                if draft.signatureImageData != nil,
                   !draft.body.plain.contains(LetterToken.signature.marker) {
                    Divider()
                    signaturePreviewImage
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Helpers

    @ViewBuilder
    private var signaturePreviewImage: some View {
        if let data = draft.signatureImageData, let image = NSImage(data: data)?.trimmedTransparentMargins() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 56)
                .padding(4)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("(no signature drawn)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .italic()
        }
    }

    private func syncDraft() {
        if let letter = store.manuscript(for: versionRef)?.letterToEditor, letter != draft {
            draft = letter
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

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if let data = slot.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 56)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            slot.imageData = nil
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

            PlainTextEditor(text: $slot.text, alignment: textAlignment)
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
        .frame(maxWidth: .infinity)
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
            slot.imageData = data
        } else if let image = NSImage(contentsOf: url) {
            slot.imageData = image.pngData(maxDimension: 1000)
        }
    }
}

// MARK: - HeaderSlotPreview

/// One letterhead slot as it will appear: image above text, slot-aligned.
struct HeaderSlotPreview: View {
    let slot: LetterHeaderSlot
    let alignment: HorizontalAlignment

    private var frameAlignment: Alignment {
        switch alignment {
        case .center:   return .center
        case .trailing: return .trailing
        default:        return .leading
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            if let data = slot.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 56)
            }
            if !slot.text.isEmpty {
                Text(slot.text)
                    .font(.callout)
                    .multilineTextAlignment(alignment == .center ? .center
                                            : alignment == .trailing ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
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
