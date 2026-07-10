// FiguresView.swift
//
// Two-pane view for managing manuscript figures.
//
// Layout (HSplitView):
//   LEFT  — a thumbnail grid of all figures + an "Add Figure" tile
//   RIGHT — FigureEditor for the selected figure, or a placeholder
//
// Image files are imported from disk and copied into the manuscript's
// figures/ folder by PersistenceService.  The figure model stores only the
// file name; the actual image bytes live on disk.
//
// Figures can be added by clicking "Add Figure", then dragging or picking an
// image file in the FigureEditor on the right.

import SwiftUI
import AppKit                  // needed for NSImage
import UniformTypeIdentifiers  // for UTType.fileURL / UTType.image

// MARK: - FiguresView

/// The figures panel: thumbnail grid on the left, detail editor on the right.
struct FiguresView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// UUID of the selected figure.
    @State private var selectedID: UUID?

    /// Figures sorted by number (Figure 1, Figure 2, …).
    private var figures: [Figure] {
        (store.manuscript(for: versionRef)?.figures ?? []).sorted { $0.number < $1.number }
    }

    var body: some View {
        if figures.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("No Figures Yet")
                    .font(.title3.weight(.semibold))
                Text("Add a figure to get started.")
                    .foregroundStyle(.secondary)
                Button {
                    store.addFigure(ref: versionRef)
                } label: {
                    Label("Add Figure", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                // MARK: Left — thumbnail grid
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                            ForEach(figures) { figure in
                                FigureThumbnail(
                                    figure: figure,
                                    isSelected: selectedID == figure.id,
                                    onTap: { selectedID = figure.id },
                                    onDelete: { deleteFigure(figure) }
                                )
                            }

                            Button {
                                store.addFigure(ref: versionRef)
                                selectedID = store.manuscript(for: versionRef)?.figures.last?.id
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("Add Figure")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 140, height: 120)
                                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3), style: StrokeStyle(dash: [5])))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(16)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 280)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
                .onAppear { autoSelect() }
                .onChange(of: figures.map(\.id)) { _, _ in autoSelect() }

                // MARK: Right — figure editor
                if let id = selectedID,
                   let figure = figures.first(where: { $0.id == id }) {
                    FigureEditor(figure: figure, versionRef: versionRef)
                } else {
                    Color.clear
                }
            }
        }
    }

    private func autoSelect() {
        if selectedID == nil || !figures.contains(where: { $0.id == selectedID }) {
            selectedID = figures.first?.id
        }
    }

    private func deleteFigure(_ figure: Figure) {
        guard let idx = store.manuscript(for: versionRef)?.figures.firstIndex(where: { $0.id == figure.id }) else { return }
        store.deleteFigures(at: IndexSet([idx]), ref: versionRef)
        if selectedID == figure.id {
            selectedID = figures.first(where: { $0.id != figure.id })?.id
        }
    }
}

// MARK: - FigureThumbnail

/// A single tile in the figure grid: image preview (if available) or placeholder icon,
/// plus the figure number and title below.
struct FigureThumbnail: View {
    @Environment(ManuscriptStore.self) private var store
    let figure: Figure
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.1)).frame(height: 90)
                    if let url = store.figureURL(for: figure),
                       let image = NSImage(contentsOf: url) {
                        // Thumbnails show the cropped result (what will export).
                        Image(nsImage: FigureImaging.processed(image, crop: figure.crop, scalePercent: nil))
                            .resizable()
                            .scaledToFill()
                            .frame(height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                Text("Fig. \(figure.number)").font(.caption.weight(.medium))
                Text(figure.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // Delete button pinned to top-right corner of the tile.
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.background).padding(2))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Delete figure")
        }
        .frame(width: 140)
    }
}

// MARK: - FigureEditor

/// The detail form for one figure: image import zone, metadata fields, and caption.
struct FigureEditor: View {
    @Environment(ManuscriptStore.self) private var store
    let figure: Figure
    /// Which version this figure belongs to.
    var versionRef: VersionRef = .source

    /// Mutable working copy.
    @State private var draft: Figure
    /// Controls the system file-picker sheet.
    @State private var isImporting = false

    init(figure: Figure, versionRef: VersionRef = .source) {
        self.figure = figure
        self.versionRef = versionRef
        _draft = State(initialValue: figure)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Image preview / drop zone.
                imageZone
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.2)))
                    // Accept files dragged from Finder.
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }

                Form {
                    imageSourceSection
                    Section("Metadata") {
                        LabeledContent("Number") {
                            TextField("", value: $draft.number, format: .number)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Title", text: $draft.title)
                        TextField("Alt text (accessibility)", text: $draft.altText)
                    }
                    Section("Caption") {
                        TextEditor(text: $draft.caption)
                            .frame(minHeight: 80)
                            .font(.callout)
                    }
                    dataSourceSection
                }
                .formStyle(.grouped)
            }
            .padding(16)
        }
        .onChange(of: draft.title)      { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.caption)    { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.altText)    { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.number)     { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.dataAssetID){ _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.chartType)  { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.chartQuery) { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.imageAssetID) { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.crop)         { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: draft.scalePercent) { _, _ in store.updateFigure(draft, ref: versionRef) }
        .onChange(of: figure.id)        { _, _ in draft = figure }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                store.importFigureFile(from: url, for: figure.id, ref: versionRef)
                url.stopAccessingSecurityScopedResource()
                draft = store.manuscript(for: versionRef)?.figures.first { $0.id == figure.id } ?? draft
            }
        }
    }

    // MARK: - Image source section

    /// Image assets from the central Data library (Data lives at the source level).
    private var imageAssets: [DataAsset] {
        (store.manuscript?.dataAssets ?? []).filter { $0.type == .image }
    }

    private var hasImage: Bool { store.figureURL(for: draft) != nil }

    @ViewBuilder
    private var imageSourceSection: some View {
        Section("Image") {
            if !imageAssets.isEmpty {
                Picker("From Data library", selection: Binding(
                    get: { draft.imageAssetID },
                    set: { newValue in
                        draft.imageAssetID = newValue
                        draft.crop = nil          // crop is per-image
                    }
                )) {
                    Text(draft.fileName != nil ? "Imported file" : "None").tag(Optional<UUID>.none)
                    ForEach(imageAssets) { asset in
                        Text(asset.name).tag(Optional(asset.id))
                    }
                }
            }
            if hasImage {
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { draft.scalePercent ?? 100 },
                            set: { draft.scalePercent = $0 >= 99.5 ? nil : $0 }
                        ), in: 10...100, step: 5)
                        .frame(width: 160)
                        Text("\(Int(draft.scalePercent ?? 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Crop") {
                    HStack(spacing: 8) {
                        Text(draft.crop == nil ? "Full image" : "Custom")
                            .foregroundStyle(.secondary)
                        Button("Reset") { draft.crop = nil }
                            .disabled(draft.crop == nil)
                    }
                }
            }
        }
    }

    // MARK: - Data source section

    private var csvAssets: [DataAsset] {
        (store.manuscript(for: versionRef)?.dataAssets ?? []).filter { $0.type == .csv }
    }

    @ViewBuilder
    private var dataSourceSection: some View {
        Section("Data Source (Chart)") {
            Picker("CSV Data", selection: Binding(
                get: { draft.dataAssetID },
                set: { draft.dataAssetID = $0 }
            )) {
                Text("None (imported image)").tag(Optional<UUID>.none)
                ForEach(csvAssets) { asset in
                    Text(asset.name).tag(Optional(asset.id))
                }
            }
            if draft.dataAssetID != nil {
                Picker("Chart Type", selection: Binding(
                    get: { draft.chartType ?? .bar },
                    set: { draft.chartType = $0 }
                )) {
                    ForEach(ChartType.allCases, id: \.self) { ct in
                        Label(ct.label, systemImage: ct.systemImage).tag(ct)
                    }
                }
                TextField("SQL Query", text: Binding(
                    get: { draft.chartQuery ?? "SELECT * FROM data" },
                    set: { draft.chartQuery = $0 }
                ), axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2...5)
            }
        }
    }

    /// Shows the crop editor over the image, or a drop-zone prompt.
    @ViewBuilder
    private var imageZone: some View {
        if let url = store.figureURL(for: draft),
           let image = NSImage(contentsOf: url) {
            VStack(spacing: 4) {
                CropAdjustView(image: image, crop: Binding(
                    get: { draft.crop },
                    set: { draft.crop = $0 }
                ))
                .padding(8)
                Text("Drag inside the frame to move the crop; drag a corner to resize.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Drop image here, pick one from the Data library below, or").foregroundStyle(.secondary)
                Button("Choose File…") { isImporting = true }.buttonStyle(.bordered)
            }
        }
    }

    /// Handles a file URL dropped onto the image zone.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            DispatchQueue.main.async {
                store.importFigureFile(from: url, for: figure.id)
            }
        }
        return true
    }
}

// MARK: - CropAdjustView

/// Interactive crop editor: the image is shown aspect-fit with a draggable,
/// corner-resizable crop frame over it.  The binding stores the crop
/// normalized (0–1, origin top-left); nil means the full image.  Changes are
/// committed when a drag ends (not per tick) to keep saves cheap.
struct CropAdjustView: View {
    let image: NSImage
    @Binding var crop: CGRect?

    /// Crop shown while a drag is in flight (committed on gesture end).
    @State private var live: CGRect?
    /// The crop value at the start of the current drag.
    @State private var dragStart: CGRect?

    private var effectiveCrop: CGRect {
        live ?? crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            let frame = viewRect(for: effectiveCrop, in: fitted)

            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Dim everything outside the crop frame.
                dimming(around: frame, in: fitted)

                // The crop frame: draggable body + corner handles.
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .background(Color.clear)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(in: fitted))

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner, frame: frame, fitted: fitted)
                }
            }
        }
        .frame(height: 240)
    }

    // MARK: geometry

    /// Aspect-fit rect of the image within the container.
    private func fittedRect(in container: CGSize) -> CGRect {
        let size = image.size
        guard size.width > 0, size.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func viewRect(for normalized: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + normalized.minX * fitted.width,
               y: fitted.minY + normalized.minY * fitted.height,
               width: normalized.width * fitted.width,
               height: normalized.height * fitted.height)
    }

    // MARK: dimming

    @ViewBuilder
    private func dimming(around frame: CGRect, in fitted: CGRect) -> some View {
        let dim = Color.black.opacity(0.35)
        Group {
            Rectangle().fill(dim)   // top strip
                .frame(width: fitted.width, height: max(frame.minY - fitted.minY, 0))
                .offset(x: fitted.minX, y: fitted.minY)
            Rectangle().fill(dim)   // bottom strip
                .frame(width: fitted.width, height: max(fitted.maxY - frame.maxY, 0))
                .offset(x: fitted.minX, y: frame.maxY)
            Rectangle().fill(dim)   // left strip
                .frame(width: max(frame.minX - fitted.minX, 0), height: frame.height)
                .offset(x: fitted.minX, y: frame.minY)
            Rectangle().fill(dim)   // right strip
                .frame(width: max(fitted.maxX - frame.maxX, 0), height: frame.height)
                .offset(x: frame.maxX, y: frame.minY)
        }
        .allowsHitTesting(false)
    }

    // MARK: gestures

    private func moveGesture(in fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = effectiveCrop }
                guard let start = dragStart else { return }
                var c = start
                c.origin.x = min(max(start.minX + value.translation.width / fitted.width, 0), 1 - c.width)
                c.origin.y = min(max(start.minY + value.translation.height / fitted.height, 0), 1 - c.height)
                live = c
            }
            .onEnded { _ in commit() }
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(_ corner: Corner, frame: CGRect, fitted: CGRect) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeft:     point = CGPoint(x: frame.minX, y: frame.minY)
        case .topRight:    point = CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft:  point = CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: point = CGPoint(x: frame.maxX, y: frame.maxY)
        }
        return Circle()
            .fill(Color.accentColor)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .position(point)
            .gesture(resizeGesture(corner, in: fitted))
    }

    private func resizeGesture(_ corner: Corner, in fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = effectiveCrop }
                guard let start = dragStart else { return }
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                let minSize: CGFloat = 0.05
                var c = start
                switch corner {
                case .topLeft:
                    let nx = min(max(start.minX + dx, 0), start.maxX - minSize)
                    let ny = min(max(start.minY + dy, 0), start.maxY - minSize)
                    c = CGRect(x: nx, y: ny, width: start.maxX - nx, height: start.maxY - ny)
                case .topRight:
                    let nw = min(max(start.width + dx, minSize), 1 - start.minX)
                    let ny = min(max(start.minY + dy, 0), start.maxY - minSize)
                    c = CGRect(x: start.minX, y: ny, width: nw, height: start.maxY - ny)
                case .bottomLeft:
                    let nx = min(max(start.minX + dx, 0), start.maxX - minSize)
                    let nh = min(max(start.height + dy, minSize), 1 - start.minY)
                    c = CGRect(x: nx, y: start.minY, width: start.maxX - nx, height: nh)
                case .bottomRight:
                    c.size.width  = min(max(start.width + dx, minSize), 1 - start.minX)
                    c.size.height = min(max(start.height + dy, minSize), 1 - start.minY)
                }
                live = c
            }
            .onEnded { _ in commit() }
    }

    /// Commits the in-flight crop to the binding; a full-image crop becomes nil.
    private func commit() {
        defer { live = nil; dragStart = nil }
        guard let final = live else { return }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        crop = final.insetBy(dx: -0.005, dy: -0.005).contains(full) ? nil : final
    }
}
