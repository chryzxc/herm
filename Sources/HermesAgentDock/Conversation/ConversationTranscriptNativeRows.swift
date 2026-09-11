import AppKit
import Combine
import Foundation

/// Presentation cache for the small thumbnails shown inside transcript rows.
/// The canonical message still owns the original image; this cache only keeps
/// disposable display-sized copies so cell reuse never rescales source images.
@MainActor
private enum ConversationThumbnailCache {
    private final class Entry: NSObject {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 512
        return cache
    }()

    static func image(_ source: NSImage, key: String, size: CGFloat = 220) -> NSImage {
        let cacheKey = "\(key):\(Int(size.rounded()))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.image }
        let target = NSSize(width: size, height: size)
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let sourceSize = source.size
        let scale = min(
            target.width / max(1, sourceSize.width),
            target.height / max(1, sourceSize.height)
        )
        let drawnSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawnRect = NSRect(
            x: (target.width - drawnSize.width) / 2,
            y: (target.height - drawnSize.height) / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
        source.draw(in: drawnRect, from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        cache.setObject(Entry(result), forKey: cacheKey, cost: Int(size * size * 4))
        return result
    }
}
struct ConversationMessageSnapshot {
    let id: UUID
    let role: ChatMessage.Role
    let text: String
    let images: [NSImage]
    let timestamp: Date
    let modelName: String?
    let responseDuration: TimeInterval?
    let isSteering: Bool
    let steeringStatus: String?
    let isError: Bool
    let botDisplayName: String?
    let attributedText: NSAttributedString
}

enum ConversationNativeRowSnapshot {
    case message(ConversationMessageSnapshot)
    case streaming(id: UUID, timestamp: Date, modelName: String?, responseDuration: TimeInterval?, text: String)
}

enum ConversationTranscriptRevision {
    /// Extends the message's stable text revision with the small set of
    /// presentation fields that can change after text is finalized. This is
    /// intentionally O(1); it never hashes the Markdown body again.
    static func message(_ message: ChatMessage) -> Int {
        var hasher = Hasher()
        hasher.combine(message.contentRevision)
        hasher.combine(message.role == .user)
        hasher.combine(message.images.count)
        hasher.combine(message.isSteering)
        hasher.combine(message.steeringStatus)
        hasher.combine(message.isError)
        hasher.combine(message.modelName)
        hasher.combine(message.responseDuration)
        hasher.combine(message.botProfileID)
        hasher.combine(message.botDisplayName)
        return hasher.finalize()
    }
}

@MainActor
struct ConversationTranscriptProjection {
    let rows: [ConversationTranscriptRowDescriptor]
    let nativeSnapshots: [String: ConversationNativeRowSnapshot]

    static let empty = ConversationTranscriptProjection(rows: [], nativeSnapshots: [:])

    init(rows: [ConversationTranscriptRowDescriptor], nativeSnapshots: [String: ConversationNativeRowSnapshot]) {
        self.rows = rows
        self.nativeSnapshots = nativeSnapshots
    }

    init(
        messages: [ChatMessage],
        limit: Int,
        streamingID: UUID?,
        streamingText: String,
        hasApproval: Bool,
        approvalRevision: Int,
        hasActivity: Bool,
        activityRevision: Int,
        isIdle: Bool
    ) {
        let visible = ConversationMessageWindow.visibleMessages(messages, limit: limit)
        var rows: [ConversationTranscriptRowDescriptor] = []
        var snapshots: [String: ConversationNativeRowSnapshot] = [:]
        if messages.isEmpty && isIdle {
            rows.append(.init(id: "startup", kind: .startup))
        }
        let hiddenCount = messages.count - visible.count
        if hiddenCount > 0 {
            rows.append(.init(id: "history-placeholder", revision: hiddenCount, kind: .historyPlaceholder))
        }
        for message in visible {
            let rowID = message.id.uuidString
            let isStreaming = message.id == streamingID
            rows.append(.init(
                id: rowID,
                revision: ConversationTranscriptRevision.message(message),
                kind: isStreaming ? .streaming : .message
            ))
            if isStreaming {
                snapshots[rowID] = .streaming(
                    id: message.id,
                    timestamp: message.timestamp,
                    modelName: message.modelName,
                    responseDuration: message.responseDuration,
                    text: streamingText
                )
            } else {
                snapshots[rowID] = .message(
                    ConversationMessageSnapshot(
                        id: message.id,
                        role: message.role,
                        text: message.text,
                        images: message.images,
                        timestamp: message.timestamp,
                        modelName: message.modelName,
                        responseDuration: message.responseDuration,
                        isSteering: message.isSteering,
                        steeringStatus: message.steeringStatus,
                        isError: message.isError,
                        botDisplayName: message.botDisplayName,
                        attributedText: ConversationTranscriptRenderCache.attributedText(for: message)
                    )
                )
            }
        }
        if hasApproval {
            rows.append(.init(id: "approval", revision: approvalRevision, kind: .approval))
        }
        if hasActivity {
            rows.append(.init(id: "activity", revision: activityRevision, kind: .activity))
        }
        self.rows = rows
        self.nativeSnapshots = snapshots
    }
}

/// Owns disposable transcript presentation state without becoming a second
/// message store. `DockModel.messages` remains canonical; this object only
/// retains prepared row snapshots and stable descriptor arrays between broad
/// SwiftUI updates elsewhere in the popover.
@MainActor
final class ConversationTranscriptProjectionStore: ObservableObject {
    @Published private(set) var projection = ConversationTranscriptProjection.empty
    private var messageSnapshots: [UUID: (revision: Int, snapshot: ConversationNativeRowSnapshot)] = [:]
    private var lastSessionID: String?

    func update(
        messages: [ChatMessage],
        limit: Int,
        streamingID: UUID?,
        streamingText: String,
        hasApproval: Bool,
        approvalRevision: Int,
        hasActivity: Bool,
        activityRevision: Int,
        isIdle: Bool,
        sessionID: String?
    ) {
        if sessionID != lastSessionID {
            messageSnapshots.removeAll(keepingCapacity: true)
            lastSessionID = sessionID
        }

        let visible = ConversationMessageWindow.visibleMessages(messages, limit: limit)
        let visibleIDs = Set(visible.map(\.id))
        messageSnapshots.keys
            .filter { !visibleIDs.contains($0) }
            .forEach { messageSnapshots.removeValue(forKey: $0) }
        var rows: [ConversationTranscriptRowDescriptor] = []
        var snapshots: [String: ConversationNativeRowSnapshot] = [:]
        if messages.isEmpty && isIdle {
            rows.append(.init(id: "startup", kind: .startup))
        }
        let hiddenCount = messages.count - visible.count
        if hiddenCount > 0 {
            rows.append(.init(id: "history-placeholder", revision: hiddenCount, kind: .historyPlaceholder))
        }
        for message in visible {
            let rowID = message.id.uuidString
            let isStreaming = message.id == streamingID
            let presentationRevision = ConversationTranscriptRevision.message(message)
            rows.append(.init(id: rowID, revision: presentationRevision, kind: isStreaming ? .streaming : .message))
            if isStreaming {
                snapshots[rowID] = .streaming(
                    id: message.id,
                    timestamp: message.timestamp,
                    modelName: message.modelName,
                    responseDuration: message.responseDuration,
                    text: streamingText
                )
                continue
            }
            if let cached = messageSnapshots[message.id], cached.revision == presentationRevision {
                snapshots[rowID] = cached.snapshot
            } else {
                let snapshot: ConversationNativeRowSnapshot = .message(
                    ConversationMessageSnapshot(
                        id: message.id,
                        role: message.role,
                        text: message.text,
                        images: message.images,
                        timestamp: message.timestamp,
                        modelName: message.modelName,
                        responseDuration: message.responseDuration,
                        isSteering: message.isSteering,
                        steeringStatus: message.steeringStatus,
                        isError: message.isError,
                        botDisplayName: message.botDisplayName,
                        attributedText: ConversationTranscriptRenderCache.attributedText(for: message)
                    )
                )
                messageSnapshots[message.id] = (presentationRevision, snapshot)
                snapshots[rowID] = snapshot
            }
        }
        if hasApproval {
            rows.append(.init(id: "approval", revision: approvalRevision, kind: .approval))
        }
        if hasActivity {
            rows.append(.init(id: "activity", revision: activityRevision, kind: .activity))
        }
        projection = ConversationTranscriptProjection(rows: rows, nativeSnapshots: snapshots)
    }
}

struct ConversationRowLayoutKey: Hashable {
    let sessionID: String?
    let rowID: String
    let revision: Int
    let width: Int
    let scale: Int
}

struct ConversationRowLayout: Equatable {
    let height: CGFloat
}

@MainActor
final class ConversationRowLayoutStore {
    private var values: [ConversationRowLayoutKey: ConversationRowLayout] = [:]

    subscript(key: ConversationRowLayoutKey) -> ConversationRowLayout? {
        get { values[key] }
        set { values[key] = newValue }
    }

    var keys: [ConversationRowLayoutKey] { Array(values.keys) }

    func removeValue(forKey key: ConversationRowLayoutKey) {
        values.removeValue(forKey: key)
    }

    func removeAll(keepingCapacity: Bool) {
        values.removeAll(keepingCapacity: keepingCapacity)
    }
}

@MainActor
enum ConversationTranscriptRenderCache {
    private final class Entry: NSObject {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 700
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func attributedText(for message: ChatMessage) -> NSAttributedString {
        let key = "\(message.id.uuidString):\(message.contentRevision):\(message.isError)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = makeAttributedText(message)
        cache.setObject(Entry(value), forKey: key, cost: max(1, value.length * 2))
        return value
    }

    private static func makeAttributedText(_ message: ChatMessage) -> NSAttributedString {
        let source: NSAttributedString
        if let markdown = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .full)
        ) {
            source = NSAttributedString(markdown)
        } else {
            source = NSAttributedString(string: message.text)
        }

        let result = NSMutableAttributedString(attributedString: source)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: range)
        result.addAttribute(
            .foregroundColor,
            value: message.isError ? NSColor.systemOrange : NSColor.labelColor,
            range: range
        )
        return result
    }
}

enum ConversationRowLayoutEngine {
    static func layout(
        snapshot: ConversationNativeRowSnapshot,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> ConversationRowLayout {
        let available = max(80, width - 40)
        switch snapshot {
        case .message(let message):
            let textHeight = textHeight(message.attributedText, width: available)
            let imageHeight = message.images.reduce(CGFloat.zero) { partial, image in
                let size = image.size
                guard size.width > 0, size.height > 0 else { return partial }
                return partial + min(220, max(28, 220 * size.height / size.width)) + 6
            }
            let bodyHeight = message.text.isEmpty ? 0 : textHeight + 24
            let metadataHeight: CGFloat = 20
            return ConversationRowLayout(
                height: max(36, bodyHeight + imageHeight + metadataHeight + 16)
            )
        case .streaming(_, _, _, _, let text):
            let attributed = NSAttributedString(
                string: text.isEmpty ? " " : text,
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
            )
            return ConversationRowLayout(height: max(42, textHeight(attributed, width: available) + 60))
        }
    }

    private static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let rect = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}

final class ConversationNativeMessageCell: NSTableCellView {
    private let bodyTextView = NSTextView()
    private let metadataLabel = NSTextField(labelWithString: "")
    private let attributionLabel = NSTextField(labelWithString: "")
    private let imageStack = NSStackView()
    private let bubble = NSView()
    private var imageButtons: [NSButton] = []
    private var representedID: UUID?
    private var representedRevision = 0
    private var representedWidth: CGFloat = 0
    private var isStreaming = false
    private var imageAction: ((NSImage) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setup()
    }

    private func setup() {
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.borderWidth = 0.5
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.drawsBackground = false
        bodyTextView.isRichText = true
        bodyTextView.isAutomaticLinkDetectionEnabled = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.textContainerInset = NSSize(width: 16, height: 12)
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(bodyTextView)

        imageStack.orientation = .vertical
        imageStack.alignment = .trailing
        imageStack.spacing = 6
        imageStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageStack)

        attributionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        attributionLabel.textColor = .controlAccentColor
        attributionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attributionLabel)

        metadataLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metadataLabel)

            NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: imageStack.topAnchor, constant: -4),
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyTextView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            bodyTextView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            bodyTextView.topAnchor.constraint(equalTo: bubble.topAnchor),
            bodyTextView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            imageStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            imageStack.bottomAnchor.constraint(equalTo: attributionLabel.topAnchor, constant: -2),
            attributionLabel.topAnchor.constraint(greaterThanOrEqualTo: bubble.bottomAnchor, constant: 2),
            attributionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            attributionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            metadataLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            metadataLabel.topAnchor.constraint(equalTo: attributionLabel.bottomAnchor, constant: 2),
            metadataLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    func setSnapshot(
        _ snapshot: ConversationNativeRowSnapshot,
        revision: Int,
        width: CGFloat,
        imageAction: ((NSImage) -> Void)?
    ) {
        let id: UUID
        switch snapshot {
        case .message(let message): id = message.id
        case .streaming(let streamingID, _, _, _, _): id = streamingID
        }
        guard representedID != id || representedRevision != revision || abs(representedWidth - width) > 1 else {
            self.imageAction = imageAction
            return
        }
        representedID = id
        representedRevision = revision
        representedWidth = width
        self.imageAction = imageAction
        isStreaming = false
        bodyTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        attributionLabel.stringValue = ""
        metadataLabel.stringValue = ""
        clearImages()

        switch snapshot {
        case .message(let message):
            isStreaming = false
            bodyTextView.textStorage?.setAttributedString(message.attributedText)
            attributionLabel.stringValue = message.botDisplayName ?? ""
            metadataLabel.stringValue = metadata(timestamp: message.timestamp, modelName: message.modelName, duration: message.responseDuration)
            setImages(message.images, rowID: message.id.uuidString)
        case .streaming(_, let timestamp, let modelName, let duration, let text):
            isStreaming = true
            updateStreamingText(text)
            metadataLabel.stringValue = metadata(timestamp: timestamp, modelName: modelName, duration: duration)
        }
        applyAppearance()
    }

    func updateStreamingText(_ text: String) {
        guard isStreaming else { return }
        let value = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        )
        bodyTextView.textStorage?.setAttributedString(value)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        representedRevision = 0
        representedWidth = 0
        imageAction = nil
        isStreaming = false
        bodyTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        attributionLabel.stringValue = ""
        metadataLabel.stringValue = ""
        clearImages()
    }

    private func applyAppearance() {
        bubble.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        bubble.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    private func setImages(_ images: [NSImage], rowID: String) {
        while imageButtons.count < images.count {
            let button = NSButton(image: NSImage(size: NSSize(width: 1, height: 1)), target: self, action: #selector(imageClicked(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "Open image preview"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            button.heightAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            imageStack.addArrangedSubview(button)
            imageButtons.append(button)
        }
        for (index, button) in imageButtons.enumerated() {
            if index < images.count {
                button.image = ConversationThumbnailCache.image(
                    images[index],
                    key: "\(rowID):\(index):\(ObjectIdentifier(images[index]).hashValue)"
                )
                button.isHidden = false
            } else {
                button.image = nil
                button.isHidden = true
            }
        }
    }

    private func clearImages() {
        for button in imageButtons {
            button.image = nil
            button.isHidden = true
        }
    }

    @objc private func imageClicked(_ sender: NSButton) {
        guard let image = sender.image else { return }
        imageAction?(image)
    }

    private func metadata(timestamp: Date, modelName: String?, duration: TimeInterval?) -> String {
        var result = HumanDateFormatting.timeOnly(timestamp)
        if let duration { result += " · \(ResponseDurationFormatting.string(seconds: duration))" }
        if let modelName { result += " · \(modelName)" }
        return result
    }
}
