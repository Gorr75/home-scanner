import PhotosUI
import SwiftUI
import UIKit
import RoomScanCore

struct InventoryListView: View {
    @Environment(HomeStore.self) private var store

    let homeID: UUID
    var roomID: UUID?

    @State private var query = ""
    @State private var editor: InventoryRoute?
    @State private var errorMessage: String?

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        PaperScreen {
            if let home {
                let rows = filtered(home)
                List {
                    Section {
                        totalsHeader(InventoryMath.homeTotal(in: home), title: "This home")
                        ForEach(InventoryMath.rooms(in: home)) { room in
                            if room.totals.count > 0 {
                                LabeledContent(room.name) {
                                    Text(priceText(room.totals))
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        TextField("Search name, brand, serial", text: $query)
                            .textInputAutocapitalization(.never)
                    }
                    if rows.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No items yet" : "No matches",
                            systemImage: "shippingbox",
                            description: Text(query.isEmpty
                                ? "Add what RoomPlan found, or type an item in by hand."
                                : "Try a brand, a serial, or a room name.")
                        )
                    } else {
                        Section("Items") {
                            ForEach(rows, id: \.item.id) { row in
                                Button {
                                    editor = InventoryRoute(roomID: row.room.id, item: row.item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.item.name.isEmpty ? "Untitled" : row.item.name)
                                            .foregroundStyle(Theme.ink)
                                        Text(caption(row.item, room: row.room))
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Home missing", systemImage: "house")
            }
        }
        .navigationTitle(roomTitle)
        .navigationBarTitleDisplayMode(.inline)
        .paperChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add item") { addManual() }
                    if let roomID {
                        Button("Add scanned items in this room") { merge(roomID) }
                    } else {
                        Button("Add scanned items") { mergeAll() }
                    }
                    Divider()
                    Button("Share CSV") { shareCSV() }
                    Button("Share insurance PDF") { sharePDF() }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Inventory actions")
            }
        }
        .sheet(item: $editor) { route in
            InventoryEditorSheet(
                homeID: homeID,
                roomID: route.roomID,
                item: route.item,
                onSave: { item in
                    save(item, roomID: route.roomID)
                },
                onDelete: { item in
                    remove(item, roomID: route.roomID)
                }
            )
        }
        .alert("Couldn't update the inventory", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var roomTitle: String {
        if let roomID, let name = home?.room(id: roomID)?.name {
            return name
        }
        return "Inventory"
    }

    private func filtered(_ home: Home) -> [(room: Room, item: InventoryItem)] {
        InventoryMath.matching(query, in: home).filter { row in
            roomID == nil || row.room.id == roomID
        }
    }

    private func caption(_ item: InventoryItem, room: Room) -> String {
        var parts = [room.name, item.category]
        if let brand = item.brand, !brand.isEmpty { parts.append(brand) }
        if let model = item.model, !model.isEmpty { parts.append(model) }
        if let price = item.price { parts.append(InventoryPDF.amount(price)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func totalsHeader(_ totals: InventoryTotals, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text("\(totals.count) items · \(totals.pricedCount) priced · \(InventoryPDF.amount(totals.totalPrice))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 4)
    }

    private func priceText(_ totals: InventoryTotals) -> String {
        "\(totals.count) · \(InventoryPDF.amount(totals.totalPrice))"
    }

    private func addManual() {
        guard let home else { return }
        let room = roomID ?? home.rooms.first?.id
        guard let room else {
            errorMessage = "Scan a room before adding an item."
            return
        }
        editor = InventoryRoute(
            roomID: room,
            item: InventoryItem(id: UUID(), name: "", category: "", source: .manual)
        )
    }

    private func merge(_ room: UUID) {
        do {
            try store.update(homeId: homeID) { $0.mergeInventorySuggestions(in: room) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeAll() {
        guard let home else { return }
        do {
            try store.update(homeId: homeID) { home in
                for room in home.rooms {
                    home.mergeInventorySuggestions(in: room.id)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ item: InventoryItem, roomID: UUID) {
        do {
            try store.update(homeId: homeID) { $0.upsertInventory(item, in: roomID) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ item: InventoryItem, roomID: UUID) {
        for relative in item.photos + [item.receipt].compactMap({ $0 }) {
            store.removeMedia(homeId: homeID, relative: relative)
        }
        do {
            try store.update(homeId: homeID) { $0.deleteInventory(id: item.id, in: roomID) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareCSV() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try InventoryPDF.csvURL(for: home))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sharePDF() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try InventoryPDF.fileURL(for: home, image: { relative in
                guard let data = store.mediaData(homeId: homeID, relative: relative) else { return nil }
                return UIImage(data: data)
            }))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension InventoryRoomTotal: Identifiable {
    public var id: UUID { roomID }
}

struct InventoryRoute: Identifiable {
    var roomID: UUID
    var item: InventoryItem
    var id: UUID { item.id }
}

struct InventoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeStore.self) private var store

    let homeID: UUID
    let roomID: UUID
    @State private var draft: InventoryItem
    @State private var priceText: String
    @State private var hasPurchaseDate: Bool
    @State private var photos: [UIImage]
    @State private var receiptImage: UIImage?
    @State private var photosChanged = false
    @State private var receiptChanged = false
    @State private var showCamera = false
    @State private var cameraTarget: CameraTarget = .photo
    @State private var libraryItem: PhotosPickerItem?
    @State private var libraryTarget: CameraTarget = .photo
    @State private var confirmingDelete = false

    var onSave: (InventoryItem) -> Void
    var onDelete: (InventoryItem) -> Void

    private enum CameraTarget {
        case photo
        case receipt
    }

    init(homeID: UUID, roomID: UUID, item: InventoryItem, onSave: @escaping (InventoryItem) -> Void, onDelete: @escaping (InventoryItem) -> Void) {
        self.homeID = homeID
        self.roomID = roomID
        _draft = State(initialValue: item)
        _priceText = State(initialValue: item.price.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "")
        _hasPurchaseDate = State(initialValue: item.purchaseDate != nil)
        _photos = State(initialValue: [])
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $draft.name)
                    TextField("Category", text: $draft.category)
                    TextField("Brand", text: optionalText(\.brand))
                    TextField("Model", text: optionalText(\.model))
                    TextField("Serial", text: optionalText(\.serial))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Purchase") {
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                    Toggle("Purchase date", isOn: $hasPurchaseDate)
                    if hasPurchaseDate {
                        DatePicker(
                            "Date",
                            selection: Binding(
                                get: { draft.purchaseDate ?? Date() },
                                set: { draft.purchaseDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                    }
                }
                Section("Link") {
                    linkPicker
                    if draft.position != nil {
                        Text(positionCaption)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                        Button("Clear position") {
                            draft.position = nil
                            draft.furnitureId = nil
                            draft.objectId = nil
                        }
                    }
                }
                Section("Photos") {
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(photos.indices, id: \.self) { index in
                                    Image(uiImage: photos[index])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                    }
                    photoButtons(target: .photo, title: "Add photo")
                    if !photos.isEmpty {
                        Button("Remove photos", role: .destructive) {
                            photos = []
                            photosChanged = true
                        }
                    }
                }
                Section("Receipt") {
                    if let receiptImage {
                        Image(uiImage: receiptImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    photoButtons(target: .receipt, title: "Add receipt")
                    if receiptImage != nil {
                        Button("Remove receipt", role: .destructive) {
                            receiptImage = nil
                            receiptChanged = true
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: optionalText(\.notes), axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Button("Delete item", role: .destructive) { confirmingDelete = true }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(draft.name.isEmpty ? "Item" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .paperChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    accept(image)
                }
                .ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                let target = libraryTarget
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        accept(image, target: target)
                    }
                }
            }
            .onAppear(perform: loadImages)
        }
    }

    private var positionCaption: String {
        guard let position = draft.position else { return "" }
        return String(
            format: "x %.2f  y %.2f  z %.2f m",
            locale: Locale(identifier: "en_US_POSIX"),
            position.x, position.y, position.z
        )
    }

    @ViewBuilder
    private var linkPicker: some View {
        if let home = store.home(id: homeID), let room = home.room(id: roomID) {
            Picker("Linked to", selection: linkSelection(room)) {
                Text("Not linked").tag(LinkChoice.none)
                ForEach(room.placedFurniture) { piece in
                    Text(FurnitureCatalog.item(id: piece.catalogId)?.name ?? piece.catalogId)
                        .tag(LinkChoice.furniture(piece.id))
                }
                ForEach(room.floorPlan.objects) { object in
                    Text(ObjectLabels.title(for: object.category))
                        .tag(LinkChoice.object(object.id))
                }
            }
        }
    }

    private func linkSelection(_ room: Room) -> Binding<LinkChoice> {
        Binding(
            get: {
                if let furnitureId = draft.furnitureId { return .furniture(furnitureId) }
                if let objectId = draft.objectId { return .object(objectId) }
                return .none
            },
            set: { choice in
                switch choice {
                case .none:
                    draft.furnitureId = nil
                    draft.objectId = nil
                case .furniture(let id):
                    draft.furnitureId = id
                    draft.objectId = nil
                    if let piece = room.placedFurniture.first(where: { $0.id == id }) {
                        draft.position = piece.position
                        if draft.source == .manual { draft.source = .catalog }
                    }
                case .object(let id):
                    draft.objectId = id
                    draft.furnitureId = nil
                    if let object = room.floorPlan.objects.first(where: { $0.id == id }) {
                        draft.position = object.center
                        if draft.source == .manual { draft.source = .detected }
                    }
                }
            }
        )
    }

    private func photoButtons(target: CameraTarget, title: String) -> some View {
        HStack {
            if SnapshotImage.cameraAvailable {
                Button(title) {
                    cameraTarget = target
                    showCamera = true
                }
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
                Label("Library", systemImage: "photo")
            }
            .simultaneousGesture(TapGesture().onEnded { libraryTarget = target })
        }
    }

    private func accept(_ image: UIImage, target: CameraTarget? = nil) {
        switch target ?? cameraTarget {
        case .photo:
            photos.append(image)
            photosChanged = true
        case .receipt:
            receiptImage = image
            receiptChanged = true
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<InventoryItem, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func loadImages() {
        photos = draft.photos.compactMap { relative in
            guard let data = store.mediaData(homeId: homeID, relative: relative) else { return nil }
            return UIImage(data: data)
        }
        if let receipt = draft.receipt, let data = store.mediaData(homeId: homeID, relative: receipt) {
            receiptImage = UIImage(data: data)
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.brand = blankToNil(draft.brand)
        draft.model = blankToNil(draft.model)
        draft.serial = blankToNil(draft.serial)
        draft.notes = blankToNil(draft.notes)
        draft.price = parsePrice(priceText)
        if !hasPurchaseDate { draft.purchaseDate = nil }
        if photosChanged {
            for relative in draft.photos {
                store.removeMedia(homeId: homeID, relative: relative)
            }
            var paths: [String] = []
            for (index, image) in photos.enumerated() {
                guard let jpeg = SnapshotImage.jpeg(from: image) else { continue }
                let relative = MediaPaths.inventoryPhoto(draft.id, index: index + 1)
                if (try? store.writeMedia(homeId: homeID, relative: relative, data: jpeg)) != nil {
                    paths.append(relative)
                }
            }
            draft.photos = paths
        }
        if receiptChanged {
            if let previous = draft.receipt {
                store.removeMedia(homeId: homeID, relative: previous)
            }
            if let receiptImage, let jpeg = SnapshotImage.jpeg(from: receiptImage) {
                let relative = MediaPaths.inventoryReceipt(draft.id)
                if (try? store.writeMedia(homeId: homeID, relative: relative, data: jpeg)) != nil {
                    draft.receipt = relative
                } else {
                    draft.receipt = nil
                }
            } else {
                draft.receipt = nil
            }
        }
        onSave(draft)
        dismiss()
    }

    private func blankToNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parsePrice(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return InventoryMath.quantize(value)
    }
}

private enum LinkChoice: Hashable {
    case none
    case furniture(UUID)
    case object(UUID)
}

enum InventoryPDF {
    static func amount(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), InventoryMath.quantize(value))
    }

    static func csvURL(for home: Home) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileStem(home.name)) inventory.csv")
        try InventoryMath.csv(for: home).data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    static func fileURL(for home: Home, image: (String) -> UIImage?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileStem(home.name)) inventory.pdf")
        try render(home, image: image).write(to: url, options: .atomic)
        return url
    }

    static func render(_ home: Home, image: (String) -> UIImage?) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let totals = InventoryMath.homeTotal(in: home)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"
        return renderer.pdfData { context in
            var y = begin(context, title: home.name, subtitle: "Insurance inventory  \(stamp.string(from: Date()))  ·  \(totals.count) items  ·  \(amount(totals.totalPrice))")
            for room in home.rooms where !room.inventoryItems.isEmpty {
                let roomTotal = InventoryMath.totals(of: room.inventoryItems)
                y = ensure(y, context: context, needed: 48)
                y = draw(room.name, at: y + 8, font: .systemFont(ofSize: 16, weight: .semibold), color: ink)
                y = draw(
                    "\(roomTotal.count) items · \(amount(roomTotal.totalPrice))",
                    at: y + 2,
                    font: .systemFont(ofSize: 11, weight: .regular),
                    color: secondary
                )
                for item in room.inventoryItems {
                    y = ensure(y, context: context, needed: 72)
                    y = draw(item.name.isEmpty ? "Untitled" : item.name, at: y + 8, font: .systemFont(ofSize: 13, weight: .semibold), color: ink)
                    var details: [String] = []
                    if !item.category.isEmpty { details.append(item.category) }
                    if let brand = item.brand, !brand.isEmpty { details.append(brand) }
                    if let model = item.model, !model.isEmpty { details.append(model) }
                    if let serial = item.serial, !serial.isEmpty { details.append("S/N \(serial)") }
                    if let price = item.price { details.append(amount(price)) }
                    if let date = item.purchaseDate { details.append(stamp.string(from: date)) }
                    if !details.isEmpty {
                        y = draw(details.joined(separator: " · "), at: y + 1, font: .systemFont(ofSize: 11, weight: .regular), color: secondary)
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        y = draw(notes, at: y + 1, font: .systemFont(ofSize: 11, weight: .regular), color: secondary)
                    }
                    if let relative = item.photos.first, let picture = image(relative) {
                        y = ensure(y, context: context, needed: 96)
                        let rect = CGRect(x: 36, y: y + 4, width: 88, height: 88)
                        picture.draw(in: rect)
                        y += 94
                    }
                }
            }
            if totals.count == 0 {
                _ = draw("No items recorded.", at: y + 16, font: .systemFont(ofSize: 13, weight: .regular), color: secondary)
            }
        }
    }

    private static func fileStem(_ name: String) -> String {
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "Home" }
        return stem.replacingOccurrences(of: "/", with: "-")
    }

    private static func begin(_ context: UIGraphicsPDFRendererContext, title: String, subtitle: String) -> Double {
        context.beginPage()
        var y = draw(title, at: 40, font: .systemFont(ofSize: 22, weight: .semibold), color: ink)
        y = draw(subtitle, at: y + 6, font: .systemFont(ofSize: 12, weight: .regular), color: secondary)
        return y + 8
    }

    private static func ensure(_ y: Double, context: UIGraphicsPDFRendererContext, needed: Double) -> Double {
        if y + needed < 800 { return y }
        return begin(context, title: "Inventory", subtitle: "Continued")
    }

    @discardableResult
    private static func draw(_ text: String, at y: Double, font: UIFont, color: UIColor) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = CGRect(x: 36, y: CGFloat(y), width: 520, height: 64)
        let used = (text as NSString).boundingRect(
            with: CGSize(width: 520, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        (text as NSString).draw(in: CGRect(x: 36, y: CGFloat(y), width: 520, height: ceil(used.height)), withAttributes: attributes)
        _ = rect
        return y + Double(ceil(used.height))
    }

    private static let ink = UIColor(red: 0.110, green: 0.098, blue: 0.082, alpha: 1)
    private static let secondary = UIColor(red: 0.361, green: 0.337, blue: 0.298, alpha: 1)
}
