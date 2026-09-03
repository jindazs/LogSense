import Foundation
import UIKit

@MainActor
final class PhotoImportCoordinator: ObservableObject {
    @Published private(set) var batch: PhotoImportBatch?
    @Published private(set) var pendingBatches: [PhotoImportBatch] = []
    @Published private(set) var statusMessage = ""
    @Published private(set) var isPresented = false
    @Published private(set) var isWorking = false

    private var token = ""
    private var store: PhotoImportStore?
    private var commitHandler: (([PhotoImportAppend], @escaping (Bool) -> Void) -> Void)?
    private var uploadTask: Task<Void, Never>?

    var progress: Double {
        guard let batch, !batch.items.isEmpty else { return 0 }
        let finished = batch.items.filter {
            $0.state == .uploaded || $0.state == .failed || $0.state == .committed
        }.count
        return Double(finished) / Double(batch.items.count)
    }

    var canPause: Bool {
        isWorking && batch?.state == .uploading
    }

    var canResume: Bool {
        !isWorking && batch?.state == .paused
    }

    var canRetry: Bool {
        !isWorking
            && batch?.state != .commitUncertain
            && (batch?.failedCount ?? 0) > 0
    }

    var canCommitSuccesses: Bool {
        !isWorking
            && batch?.state != .commitUncertain
            && (batch?.items.contains { $0.state == .uploaded } ?? false)
    }

    var canDiscard: Bool {
        !isWorking && batch?.state != .committing
    }

    func refreshQueue() {
        guard let store = try? PhotoImportStore.shared() else {
            pendingBatches = []
            return
        }
        self.store = store
        pendingBatches = store.pendingBatches()
    }

    func start(
        batchID: UUID,
        token: String,
        commitHandler: @escaping ([PhotoImportAppend], @escaping (Bool) -> Void) -> Void
    ) {
        guard !isWorking || batch?.id == batchID else {
            statusMessage = "現在のアップロードを一時停止してから別の項目を開いてください。"
            return
        }
        do {
            let store = try PhotoImportStore.shared()
            var batch = try store.recoverInterruptedStaging(batchID)
            if batch.state == .completed {
                self.store = store
                self.batch = batch
                statusMessage = "\(batch.items.count)枚を追加しました。"
                isPresented = true
                isWorking = false
                refreshQueue()
                return
            }
            self.store = store
            self.batch = batch
            self.token = token
            self.commitHandler = commitHandler
            isPresented = true

            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "Gyazo Tokenを設定してから再試行してください。"
                isWorking = false
                refreshQueue()
                return
            }
            if batch.state == .committing || batch.state == .commitUncertain {
                batch.state = .commitUncertain
                try store.save(batch)
                self.batch = batch
                statusMessage = "Cosenseへの追加結果を確認できませんでした。ページを確認してください。"
                isWorking = false
                refreshQueue()
                return
            }
            if batch.state == .paused {
                statusMessage = "アップロードを一時停止しています。"
                isWorking = false
                refreshQueue()
                return
            }
            for index in batch.items.indices where batch.items[index].state == .uploading {
                batch.items[index].state = .staged
            }
            try store.save(batch)
            self.batch = batch
            refreshQueue()
            uploadPendingItems()
        } catch {
            statusMessage = error.localizedDescription
            isPresented = true
            isWorking = false
            refreshQueue()
        }
    }

    func pause() {
        guard canPause else { return }
        statusMessage = "アップロードを一時停止しています…"
        uploadTask?.cancel()
    }

    func resume() {
        guard var batch, canResume else { return }
        for index in batch.items.indices where batch.items[index].state == .uploading {
            batch.items[index].state = .staged
        }
        batch.state = .staged
        persist(batch)
        uploadPendingItems()
    }

    func retryFailedItems() {
        guard var batch else { return }
        for index in batch.items.indices where batch.items[index].state == .failed {
            batch.items[index].state = .staged
            batch.items[index].errorMessage = nil
        }
        batch.state = .staged
        persist(batch)
        uploadPendingItems()
    }

    func commitSuccessfulItems() {
        guard var batch, let commitHandler else { return }
        let appends = PhotoImportBodyBuilder.makeAppends(from: batch.items)
        guard !appends.isEmpty else {
            statusMessage = "追加できる画像がありません。"
            return
        }

        batch.state = .committing
        persist(batch)
        isWorking = true
        statusMessage = "Cosenseへ追加しています…"

        commitHandler(appends) { [weak self] success in
            Task { @MainActor in
                guard let self, var current = self.batch else { return }
                self.isWorking = false
                if success {
                    let committedIDs = Set(appends.flatMap(\.itemIDs))
                    for index in current.items.indices where committedIDs.contains(current.items[index].id) {
                        current.items[index].state = .committed
                    }
                    current.state = current.failedCount == 0 ? .completed : .awaitingDecision
                    self.persist(current)
                    self.statusMessage = current.failedCount == 0
                        ? "\(current.items.count)枚を追加しました。"
                        : "\(current.uploadedCount)枚を追加しました。\(current.failedCount)枚は未完了です。"
                } else {
                    current.state = .commitUncertain
                    self.persist(current)
                    self.statusMessage = "Cosenseへの追加結果を確認できませんでした。ページを確認してから再試行してください。"
                }
            }
        }
    }

    func close() {
        if batch?.state == .completed, let batchID = batch?.id {
            try? store?.remove(batchID)
        }
        isPresented = false
        refreshQueue()
    }

    func discardCurrentBatch() {
        guard canDiscard, let batchID = batch?.id else { return }
        discard(batchID: batchID)
    }

    func discard(batchID: UUID) {
        guard !isWorking || batch?.id != batchID else { return }
        do {
            let store = try PhotoImportStore.shared()
            try store.remove(batchID)
            if batch?.id == batchID {
                batch = nil
                isPresented = false
                statusMessage = ""
            }
            refreshQueue()
        } catch {
            statusMessage = "アップロード項目を破棄できませんでした。\(error.localizedDescription)"
        }
    }

    private func uploadPendingItems() {
        guard var batch, let store else { return }
        let indices = batch.items.indices.filter { batch.items[$0].state == .staged }
        guard !indices.isEmpty else {
            finishUploading()
            return
        }

        batch.state = .uploading
        for index in indices {
            batch.items[index].state = .uploading
            batch.items[index].attemptCount += 1
        }
        persist(batch)
        isWorking = true
        statusMessage = "Gyazoへアップロードしています…"

        let token = token
        uploadTask = Task { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: indices.count, by: 2) {
                guard !Task.isCancelled else { break }
                let pair = Array(indices[start..<min(start + 2, indices.count)])
                await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                    for index in pair {
                        guard let current = self.batch else { continue }
                        let item = current.items[index]
                        let fileURL = store.imageURL(batchID: current.id, filename: item.localFilename)
                        group.addTask {
                            do {
                                let url = try await GyazoBatchUploader.uploadWithRetry(
                                    fileURL: fileURL,
                                    token: token
                                )
                                return (index, .success(url))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }

                    for await (index, result) in group {
                        guard var current = self.batch else { continue }
                        switch result {
                        case .success(let url):
                            current.items[index].gyazoURL = url
                            current.items[index].state = .uploaded
                            current.items[index].errorMessage = nil
                        case .failure(let error) where error.isCancellation:
                            current.items[index].state = .staged
                            current.items[index].errorMessage = nil
                        case .failure(let error):
                            current.items[index].state = .failed
                            current.items[index].errorMessage = error.localizedDescription
                        }
                        self.persist(current)
                    }
                }
            }

            if Task.isCancelled {
                self.finishPausing()
            } else {
                self.finishUploading()
            }
            self.uploadTask = nil
        }
    }

    private func finishPausing() {
        guard var batch else { return }
        for index in batch.items.indices where batch.items[index].state == .uploading {
            batch.items[index].state = .staged
        }
        batch.state = .paused
        isWorking = false
        persist(batch)
        statusMessage = "アップロードを一時停止しました。"
    }

    private func finishUploading() {
        guard var batch else { return }
        isWorking = false
        if batch.failedCount == 0 {
            persist(batch)
            commitSuccessfulItems()
        } else {
            batch.state = .awaitingDecision
            persist(batch)
            statusMessage = "\(batch.items.count)枚中\(batch.uploadedCount)枚をアップロードしました。\(batch.failedCount)枚に失敗しました。"
        }
    }

    private func persist(_ updated: PhotoImportBatch) {
        batch = updated
        do {
            try store?.save(updated)
            refreshQueue()
        } catch {
            statusMessage = "進捗を保存できませんでした。\(error.localizedDescription)"
        }
    }
}

private extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

private enum GyazoBatchUploadError: LocalizedError {
    case invalidResponse
    case server(Int)
    case invalidImage
    case invalidImageURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Gyazoから不正な応答を受信しました。"
        case .server(let status):
            return "Gyazoへのアップロードに失敗しました（HTTP \(status)）。"
        case .invalidImage:
            return "画像をJPEGへ変換できませんでした。"
        case .invalidImageURL:
            return "Gyazoの応答に画像URLがありませんでした。"
        }
    }
}

private struct PreparedUploadFile {
    let url: URL
    let shouldRemove: Bool
}

private enum GyazoBatchUploader {
    static func uploadWithRetry(fileURL: URL, token: String, maximumAttempts: Int = 3) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            do {
                return try await upload(fileURL: fileURL, token: token)
            } catch {
                guard !error.isCancellation,
                      attempt < maximumAttempts,
                      isRetryable(error) else {
                    throw error
                }
                let delay = UInt64(1 << (attempt - 1)) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private static func upload(fileURL: URL, token: String) async throws -> String {
        let prepared = try prepareJPEG(from: fileURL)
        defer {
            if prepared.shouldRemove {
                try? FileManager.default.removeItem(at: prepared.url)
            }
        }
        try Task.checkCancellation()

        let boundary = UUID().uuidString
        let multipartURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: multipartURL) }

        guard FileManager.default.createFile(atPath: multipartURL.path, contents: nil) else {
            throw GyazoBatchUploadError.invalidResponse
        }
        let handle = try FileHandle(forWritingTo: multipartURL)
        do {
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"imagedata\"; filename=\"image.jpg\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            let imageHandle = try FileHandle(forReadingFrom: prepared.url)
            defer { try? imageHandle.close() }
            while let chunk = try imageHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        var request = URLRequest(url: URL(string: "https://upload.gyazo.com/api/upload")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: multipartURL)
        guard let response = response as? HTTPURLResponse else {
            throw GyazoBatchUploadError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GyazoBatchUploadError.server(response.statusCode)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let url = object?["url"] as? String,
              URL(string: url)?.scheme?.lowercased() == "https" else {
            throw GyazoBatchUploadError.invalidImageURL
        }
        return url
    }

    private static func prepareJPEG(from sourceURL: URL) throws -> PreparedUploadFile {
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            return PreparedUploadFile(url: sourceURL, shouldRemove: false)
        }
        guard let image = UIImage(contentsOfFile: sourceURL.path),
              let data = image.jpegData(compressionQuality: 0.9) else {
            throw GyazoBatchUploadError.invalidImage
        }
        let url = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("prepared-\(UUID().uuidString).jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return PreparedUploadFile(url: url, shouldRemove: true)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case GyazoBatchUploadError.server(let status) = error {
            return status == 429 || (500..<600).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed
        ].contains(urlError.code)
    }
}
