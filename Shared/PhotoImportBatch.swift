import Foundation
import CryptoKit

enum SharedSettingsKeys {
    static let primaryProjectName = "ProjectName"
    static let photoProjectName = "PhotoProjectName"
    static let defaultPhotoProjectName = "jindazs"
}

enum PhotoImportDestination: String, Codable {
    case primary
    case photo
}

enum PhotoImportItemState: String, Codable {
    case staged
    case uploading
    case uploaded
    case failed
    case committed
    case skipped
}

enum PhotoImportBatchState: String, Codable {
    case staging
    case staged
    case uploading
    case paused
    case awaitingDecision
    case committing
    case commitUncertain
    case completed
    case failed
}

struct PhotoImportItem: Codable, Identifiable, Equatable {
    let id: UUID
    let originalIndex: Int
    let localFilename: String
    let capturedDate: String
    let camera: String?
    let lens: String?
    var originalFilename: String? = nil
    var byteSize: Int64? = nil
    var contentHash: String? = nil
    var state: PhotoImportItemState
    var gyazoURL: String?
    var attemptCount: Int
    var errorMessage: String?
}

struct PhotoImportBatch: Codable, Identifiable, Equatable {
    let id: UUID
    let destination: PhotoImportDestination
    let projectName: String
    let createdAt: Date
    var items: [PhotoImportItem]
    var state: PhotoImportBatchState

    var uploadedCount: Int {
        items.filter { $0.state == .uploaded || $0.state == .committed }.count
    }

    var failedCount: Int {
        items.filter { $0.state == .failed }.count
    }

    var skippedCount: Int {
        items.filter { $0.state == .skipped }.count
    }

    var processedCount: Int {
        uploadedCount + failedCount + skippedCount
    }

    var completionMessage: String {
        if skippedCount == items.count {
            return "\(skippedCount)枚すべて重複のためスキップしました。"
        }
        if skippedCount > 0 {
            return "\(uploadedCount)枚を追加し、\(skippedCount)枚の重複をスキップしました。"
        }
        return "\(uploadedCount)枚を追加しました。"
    }
}

struct ImageFingerprint: Equatable {
    let sha256: String
    let byteSize: Int64

    static func make(from url: URL) throws -> ImageFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteSize: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            byteSize += Int64(data.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ImageFingerprint(sha256: digest, byteSize: byteSize)
    }
}

struct UploadedPhotoRecord: Codable, Equatable {
    let contentHash: String
    let byteSize: Int64
    let originalFilename: String?
    let gyazoURL: String
    let capturedDate: String
    let uploadedAt: Date
}

struct PhotoUploadHistoryStore {
    private static let directoryName = "UploadedPhotoHistory"
    let rootURL: URL

    static func shared(fileManager: FileManager = .default) throws -> PhotoUploadHistoryStore {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: PhotoImportStore.appGroupID
        ) else {
            throw PhotoImportStoreError.appGroupUnavailable
        }
        return PhotoUploadHistoryStore(
            rootURL: container.appendingPathComponent(directoryName, isDirectory: true)
        )
    }

    func record(for contentHash: String) -> UploadedPhotoRecord? {
        guard let url = recordURL(for: contentHash),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UploadedPhotoRecord.self, from: data)
    }

    func save(_ record: UploadedPhotoRecord, fileManager: FileManager = .default) throws {
        guard let url = recordURL(for: record.contentHash) else {
            throw PhotoImportStoreError.invalidBatch
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
    }

    private func recordURL(for contentHash: String) -> URL? {
        let normalized = contentHash.lowercased()
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(hexCharacters.contains) else {
            return nil
        }
        return rootURL.appendingPathComponent("\(normalized).json", isDirectory: false)
    }
}

struct PhotoImportAppend: Equatable {
    let pageTitle: String
    let body: String
    let itemIDs: [UUID]
}

enum PhotoImportBodyBuilder {
    static func makeAppends(
        from items: [PhotoImportItem],
        maximumImagesPerAppend: Int = 10
    ) -> [PhotoImportAppend] {
        guard maximumImagesPerAppend > 0 else { return [] }

        let successful = items
            .filter { $0.gyazoURL != nil && $0.state == .uploaded }
            .sorted { $0.originalIndex < $1.originalIndex }

        let dates = successful.reduce(into: [String]()) { result, item in
            if !result.contains(item.capturedDate) {
                result.append(item.capturedDate)
            }
        }

        return dates.flatMap { date in
            let datedItems = successful.filter { $0.capturedDate == date }
            return stride(from: 0, to: datedItems.count, by: maximumImagesPerAppend).map { start in
                let end = min(start + maximumImagesPerAppend, datedItems.count)
                let chunk = Array(datedItems[start..<end])
                return PhotoImportAppend(
                    pageTitle: date,
                    body: chunk.map(makeBody).joined(separator: "\n\n"),
                    itemIDs: chunk.map(\.id)
                )
            }
        }
    }

    private static func makeBody(for item: PhotoImportItem) -> String {
        guard let gyazoURL = item.gyazoURL else { return "" }
        var lines = ["[\(gyazoURL)]"]
        let metadata = [item.camera, item.lens]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "[\($0)]" }
        if !metadata.isEmpty {
            lines.append(metadata.joined(separator: " + "))
        }
        return lines.joined(separator: "\n")
    }
}

enum PhotoImportStoreError: LocalizedError {
    case appGroupUnavailable
    case invalidBatch

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "共有ストレージを利用できません。App Group設定を確認してください。"
        case .invalidBatch:
            return "写真アップロードの情報を読み込めませんでした。"
        }
    }
}

struct PhotoImportStore {
    static let appGroupID = "group.logsense"
    private static let directoryName = "PhotoImportBatches"

    let rootURL: URL

    static func shared(fileManager: FileManager = .default) throws -> PhotoImportStore {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw PhotoImportStoreError.appGroupUnavailable
        }
        return PhotoImportStore(rootURL: container.appendingPathComponent(directoryName, isDirectory: true))
    }

    func createDirectory(for batchID: UUID, fileManager: FileManager = .default) throws -> URL {
        let directory = batchDirectory(for: batchID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func imageURL(batchID: UUID, filename: String) -> URL {
        batchDirectory(for: batchID).appendingPathComponent(filename, isDirectory: false)
    }

    func save(_ batch: PhotoImportBatch, fileManager: FileManager = .default) throws {
        _ = try createDirectory(for: batch.id, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(batch)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: manifestURL(for: batch.id), options: options)
    }

    func load(_ batchID: UUID) throws -> PhotoImportBatch {
        let data = try Data(contentsOf: manifestURL(for: batchID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(PhotoImportBatch.self, from: data),
              batch.id == batchID else {
            throw PhotoImportStoreError.invalidBatch
        }
        return batch
    }

    func pendingBatches(fileManager: FileManager = .default) -> [PhotoImportBatch] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return directories
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load($0) }
            .filter { $0.state != .completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func recoverInterruptedStaging(_ batchID: UUID) throws -> PhotoImportBatch {
        var batch = try load(batchID)
        guard batch.state == .staging else { return batch }
        guard !batch.items.isEmpty else {
            try remove(batchID)
            throw PhotoImportStoreError.invalidBatch
        }
        batch.state = .staged
        try save(batch)
        return batch
    }

    func remove(_ batchID: UUID, fileManager: FileManager = .default) throws {
        let directory = batchDirectory(for: batchID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func batchDirectory(for batchID: UUID) -> URL {
        rootURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    private func manifestURL(for batchID: UUID) -> URL {
        batchDirectory(for: batchID).appendingPathComponent("batch.json", isDirectory: false)
    }
}
