import Foundation

@MainActor
final class PhotoImportCoordinator: ObservableObject {
    @Published private(set) var batch: PhotoImportBatch?
    @Published private(set) var statusMessage = ""
    @Published private(set) var isPresented = false
    @Published private(set) var isWorking = false

    private var token = ""
    private var store: PhotoImportStore?
    private var commitHandler: (([PhotoImportAppend], @escaping (Bool) -> Void) -> Void)?

    var progress: Double {
        guard let batch, !batch.items.isEmpty else { return 0 }
        let finished = batch.items.filter {
            $0.state == .uploaded || $0.state == .failed || $0.state == .committed
        }.count
        return Double(finished) / Double(batch.items.count)
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

    func start(
        batchID: UUID,
        token: String,
        commitHandler: @escaping ([PhotoImportAppend], @escaping (Bool) -> Void) -> Void
    ) {
        do {
            let store = try PhotoImportStore.shared()
            var batch = try store.load(batchID)
            if batch.state == .completed {
                self.store = store
                self.batch = batch
                statusMessage = "\(batch.items.count)枚を追加しました。"
                isPresented = true
                isWorking = false
                return
            }
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.store = store
                self.batch = batch
                statusMessage = "Gyazo Tokenを設定してから再試行してください。"
                isPresented = true
                isWorking = false
                return
            }
            if batch.state == .committing || batch.state == .commitUncertain {
                batch.state = .commitUncertain
                try store.save(batch)
                self.store = store
                self.batch = batch
                statusMessage = "Cosenseへの追加結果を確認できませんでした。ページを確認してください。"
                isPresented = true
                isWorking = false
                return
            }
            for index in batch.items.indices where batch.items[index].state == .uploading {
                batch.items[index].state = .staged
            }
            try store.save(batch)
            self.store = store
            self.batch = batch
            self.token = token
            self.commitHandler = commitHandler
            isPresented = true
            uploadPendingItems()
        } catch {
            statusMessage = error.localizedDescription
            isPresented = true
            isWorking = false
        }
    }

    func retryFailedItems() {
        guard var batch else { return }
        for index in batch.items.indices where batch.items[index].state == .failed {
            batch.items[index].state = .staged
            batch.items[index].errorMessage = nil
        }
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
        Task {
            for start in stride(from: 0, to: indices.count, by: 2) {
                let pair = Array(indices[start..<min(start + 2, indices.count)])
                await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                    for index in pair {
                        guard let current = self.batch else { continue }
                        let item = current.items[index]
                        let fileURL = store.imageURL(batchID: current.id, filename: item.localFilename)
                        group.addTask {
                            do {
                                let url = try await GyazoBatchUploader.upload(fileURL: fileURL, token: token)
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
                        case .failure(let error):
                            current.items[index].state = .failed
                            current.items[index].errorMessage = error.localizedDescription
                        }
                        self.persist(current)
                    }
                }
            }
            finishUploading()
        }
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
        } catch {
            statusMessage = "進捗を保存できませんでした。\(error.localizedDescription)"
        }
    }
}

private enum GyazoBatchUploadError: LocalizedError {
    case invalidResponse
    case server(Int)
    case invalidImageURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Gyazoから不正な応答を受信しました。"
        case .server(let status):
            return "Gyazoへのアップロードに失敗しました（HTTP \(status)）。"
        case .invalidImageURL:
            return "Gyazoの応答に画像URLがありませんでした。"
        }
    }
}

private enum GyazoBatchUploader {
    static func upload(fileURL: URL, token: String) async throws -> String {
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
            let imageHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? imageHandle.close() }
            while let chunk = try imageHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
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
        let session = URLSession(configuration: configuration)
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
}
