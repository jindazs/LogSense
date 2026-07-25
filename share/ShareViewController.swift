import UIKit
import UniformTypeIdentifiers

private let appGroupID = "group.logsense"

/// Returns the UserDefaults for the App Group if the container exists.
/// Falls back to `.standard` when unavailable to avoid runtime warnings.
private func groupDefaults() -> UserDefaults {
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil,
       let defaults = UserDefaults(suiteName: appGroupID) {
        return defaults
    }
    LogSenseLogger.debug("[ShareExt] App Group container missing; using UserDefaults.standard")
    return .standard
}

private enum GyazoUploadError: LocalizedError {
    case requestPreparation
    case network(Error)
    case invalidResponse
    case server(statusCode: Int, message: String?)
    case invalidImageURL

    var errorDescription: String? {
        switch self {
        case .requestPreparation:
            return "画像アップロードの準備に失敗しました。"
        case .network(let error):
            return "Gyazoへ接続できませんでした。\(error.localizedDescription)"
        case .invalidResponse:
            return "Gyazoから不正な応答を受信しました。"
        case .server(let statusCode, let message):
            let detail = message.map { " \($0)" } ?? ""
            return "Gyazoへのアップロードに失敗しました（HTTP \(statusCode)）。\(detail)"
        case .invalidImageURL:
            return "Gyazoの応答に有効な画像URLがありませんでした。"
        }
    }
}

final class ShareViewController: UIViewController {
    private let imageProcessingQueue = DispatchQueue(
        label: "LogSense.ShareExtension.ImageProcessing",
        qos: .userInitiated
    )
    private var hasStartedHandlingShare = false
    private var isShowingError = false

    override func viewDidLoad() {
        super.viewDidLoad()
        LogSenseLogger.debug("[ShareExt] viewDidLoad")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        LogSenseLogger.debug("[ShareExt] viewDidAppear")
        guard !hasStartedHandlingShare else { return }
        hasStartedHandlingShare = true
        handleShare()
    }

    private func handleShare() {
        LogSenseLogger.debug("[ShareExt] handleShare start")
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            LogSenseLogger.debug("[ShareExt] No input item")
            presentError("共有された内容を読み込めませんでした。")
            return
        }
        // まず画像共有か確認
        if let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            LogSenseLogger.debug("[ShareExt] found image attachment")
            handleImage(provider: provider)
            return
        }

        LogSenseLogger.debug("[ShareExt] no image attachment, try extracting page info")

        extractPageInfo(from: item) { title, url in
            // App Group から取得。取得できない場合は標準の UserDefaults を使用
            let defaults = groupDefaults()
            let projectName = defaults.string(forKey: "ProjectName")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !projectName.isEmpty else {
                self.presentError("先にLogSenseの設定画面でプロジェクト名を設定してください。")
                return
            }
            LogSenseLogger.debug("[ShareExt] projectName = \(projectName)")
            LogSenseLogger.debug("[ShareExt] received title = \(title)")
            LogSenseLogger.debug("[ShareExt] received url = \(url.absoluteString)")

            let body = "[\(title) \(url.absoluteString)]\n#inbox"
            guard let scrapboxURL = ScrapboxURLBuilder.makePageURL(
                project: projectName,
                title: title,
                body: body
            ) else {
                LogSenseLogger.debug("[ShareExt] Failed to build Scrapbox URL")
                self.presentError("Scrapbox URLを作成できませんでした。")
                return
            }
            LogSenseLogger.debug("[ShareExt] scrapboxURL (before encode) = \(scrapboxURL)")

            // Build callback URL safely with URLComponents
            var comps = URLComponents()
            comps.scheme = "logsense"
            comps.host = "open"
            comps.queryItems = [
                URLQueryItem(name: "scrapboxUrl", value: scrapboxURL.absoluteString)
            ]

            guard let callback = comps.url else {
                LogSenseLogger.debug("[ShareExt] Failed to build callback URL via URLComponents")
                self.presentError("LogSenseを開くためのURLを作成できませんでした。")
                return
            }

            LogSenseLogger.debug("[ShareExt] callback url = \(callback.absoluteString)")
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.logsense") {
                LogSenseLogger.debug("[ShareExt] group container = \(containerURL.path)")
            } else {
                LogSenseLogger.debug("[ShareExt] group container NOT found")
            }
            LogSenseLogger.debug("[ShareExt] defaults(ProjectName)=\(defaults.string(forKey: "ProjectName") ?? "nil")")

            guard let context = self.extensionContext else {
                LogSenseLogger.debug("[ShareExt] extensionContext is nil")
                self.presentError("共有拡張を完了できませんでした。")
                return
            }
            LogSenseLogger.debug("[ShareExt] opening main app")
            self.openCallback(callback, using: context)
        }
    }

    private func handleImage(provider: NSItemProvider) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
            guard let self else { return }
            LogSenseLogger.debug("[ShareExt] load data error=\(String(describing: error))")
            guard let data else {
                LogSenseLogger.debug("[ShareExt] failed to load image data")
                self.presentError("共有された画像を読み込めませんでした。")
                return
            }

            self.imageProcessingQueue.async {
                autoreleasepool {
                    self.processImage(data)
                }
            }
        }
    }

    private func processImage(_ data: Data) {
        LogSenseLogger.debug("[ShareExt] got raw image data size=\(data.count) bytes")
        let defaults = groupDefaults()
        let projectName = defaults.string(forKey: "ProjectName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !projectName.isEmpty else {
            presentError("先にLogSenseの設定画面でプロジェクト名を設定してください。")
            return
        }

        let token = GyazoTokenStore.load(migratingFrom: defaults)
        LogSenseLogger.debug("[ShareExt] project=\(projectName) token.isEmpty=\(token.isEmpty)")
        guard !token.isEmpty else {
            presentError("先にLogSenseの設定画面でGyazo Tokenを設定してください。")
            return
        }

        let metadata = ImageMetadataReader.read(from: data)
        let date = metadata.date ?? currentDate()

        let uploadData: Data
        if let jpg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
            LogSenseLogger.debug("[ShareExt] converted image to JPEG size=\(jpg.count)")
            uploadData = jpg
        } else {
            LogSenseLogger.debug("[ShareExt] using original data for upload")
            uploadData = data
        }

        uploadImage(data: uploadData, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let urlString):
                DispatchQueue.main.async {
                    self.openUploadedImage(
                        urlString: urlString,
                        projectName: projectName,
                        date: date,
                        camera: metadata.cameraModel,
                        lens: metadata.lensModel
                    )
                }
            case .failure(let error):
                self.presentError(error.localizedDescription)
            }
        }
    }

    private func openUploadedImage(
        urlString: String,
        projectName: String,
        date: String,
        camera: String?,
        lens: String?
    ) {
        guard let scrapbox = makeScrapboxURLForImage(
            project: projectName,
            page: date,
            imageURL: urlString,
            camera: camera,
            lens: lens
        ) else {
            presentError("Scrapbox URLを作成できませんでした。")
            return
        }

        var comps = URLComponents()
        comps.scheme = "logsense"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "scrapboxUrl", value: scrapbox.absoluteString)]

        guard let callback = comps.url else {
            presentError("LogSenseを開くためのURLを作成できませんでした。")
            return
        }

        guard let context = extensionContext else {
            presentError("共有拡張を完了できませんでした。")
            return
        }
        openCallback(callback, using: context)
    }

    private func currentDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func uploadImage(
        data: Data,
        token: String,
        completion: @escaping (Result<String, GyazoUploadError>) -> Void
    ) {
        let boundary = UUID().uuidString
        var req = URLRequest(url: URL(string: "https://upload.gyazo.com/api/upload")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsense-\(UUID().uuidString).multipart")
        do {
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                completion(.failure(.requestPreparation))
                return
            }
            let file = try FileHandle(forWritingTo: temporaryURL)
            defer { try? file.close() }

            func write(_ string: String) throws {
                try file.write(contentsOf: Data(string.utf8))
            }

            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"access_token\"\r\n\r\n")
            try write("\(token)\r\n")
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"imagedata\"; filename=\"image.jpg\"\r\n")
            try write("Content-Type: image/jpeg\r\n\r\n")
            try file.write(contentsOf: data)
            try write("\r\n")
            try write("--\(boundary)--\r\n")
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: temporaryURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            completion(.failure(.requestPreparation))
            return
        }

        URLSession.shared.uploadTask(with: req, fromFile: temporaryURL) { data, response, error in
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            if let error = error {
                LogSenseLogger.debug("[ShareExt] upload error=\(error.localizedDescription)")
                completion(.failure(.network(error)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }

            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = json?["message"] as? String
                completion(.failure(.server(statusCode: httpResponse.statusCode, message: message)))
                return
            }

            guard let urlString = json?["url"] as? String,
                  let imageURL = URL(string: urlString),
                  imageURL.scheme?.lowercased() == "https" else {
                LogSenseLogger.debug("[ShareExt] upload failed to parse response")
                completion(.failure(.invalidImageURL))
                return
            }
            LogSenseLogger.debug("[ShareExt] upload success URL=\(urlString)")
            completion(.success(urlString))
        }.resume()
    }

    private func makeScrapboxURLForImage(project: String,
                                         page: String,
                                         imageURL: String,
                                         camera: String?,
                                         lens: String?) -> URL? {
        var body = "[\(imageURL)]"

        let cam = camera?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let len = lens?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let parts: [String] = [
            cam.isEmpty ? nil : "[\(cam)]",
            len.isEmpty ? nil : "[\(len)]"
        ].compactMap { $0 }

        if !parts.isEmpty {
            body += "\n" + parts.joined(separator: " + ")
        }

        return ScrapboxURLBuilder.makePageURL(project: project, title: page, body: body)
    }

    private func extractPageInfo(from item: NSExtensionItem,
                                 completion: @escaping (String, URL) -> Void) {

        let providers = item.attachments ?? []
        LogSenseLogger.debug("[ShareExt] extractPageInfo providers count=\(providers.count)")
        guard !providers.isEmpty else {
            presentError("共有された内容を読み込めませんでした。")
            return
        }

        // 1) URL を最優先で取得
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            LogSenseLogger.debug("[ShareExt] found URL provider")
            _ = provider.loadObject(ofClass: URL.self) { (url, error) in
                DispatchQueue.main.async {
                    LogSenseLogger.debug("[ShareExt] load URL error=\(String(describing: error))")
                    guard let url = url else {
                        LogSenseLogger.debug("[ShareExt] URL provider returned nil")
                        self.presentError("共有されたURLを読み込めませんでした。")
                        return
                    }
                    let title = item.attributedContentText?.string ?? url.absoluteString
                    completion(title, url)
                }
            }
            return
        }

        // 2) テキストからURLを抽出
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            LogSenseLogger.debug("[ShareExt] found String provider")
            _ = provider.loadObject(ofClass: String.self) { (text, error) in
                DispatchQueue.main.async {
                    LogSenseLogger.debug("[ShareExt] load String error=\(String(describing: error))")
                    let rawText = text ?? ""
                    if let firstURL = URL(string: rawText) {
                        completion(rawText, firstURL)
                    } else {
                        LogSenseLogger.debug("[ShareExt] String provider text did not contain URL")
                        self.presentError("共有されたテキストに有効なURLがありません。")
                    }
                }
            }
            return
        }

        // 3) どちらも取得できない場合は終了
        LogSenseLogger.debug("[ShareExt] extractPageInfo no suitable provider")
        presentError("この種類の共有には対応していません。")
    }

    private func presentError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShowingError else { return }
            self.isShowingError = true

            let alert = UIAlertController(
                title: "共有できませんでした",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "閉じる", style: .default) { _ in
                self.extensionContext?.completeRequest(returningItems: nil)
            })
            self.present(alert, animated: true)
        }
    }

    /// Attempts to open the main application with the given callback URL.
    /// Uses `extensionContext.open` and falls back to the responder chain.
    private func openCallback(_ url: URL, using context: NSExtensionContext) {
        context.open(url) { success in
            DispatchQueue.main.async {
                LogSenseLogger.debug("[ShareExt] context.open success = \(success)")
                if success || self.openViaResponderChain(url) {
                    context.completeRequest(returningItems: nil)
                } else {
                    self.presentError("LogSenseを開けませんでした。アプリを一度起動してから再試行してください。")
                }
            }
        }
    }

    @discardableResult
    private func openViaResponderChain(_ url: URL) -> Bool {
        LogSenseLogger.debug("[ShareExt] trying responder chain fallback")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                // Prefer modern API
                if app.responds(to: #selector(UIApplication.open(_:options:completionHandler:))) {
                    app.open(url, options: [:]) { success in
                        LogSenseLogger.debug("[ShareExt] Fallback UIApplication.open success = \(success)")
                    }
                    return true
                }
                // Legacy fallback (should not be used on modern iOS, but kept just in case)
                let sel = NSSelectorFromString("openURL:")
                if app.responds(to: sel) {
                    app.perform(sel, with: url)
                    LogSenseLogger.debug("[ShareExt] Fallback openURL via responder chain (legacy)")
                    return true
                }
            }
            responder = r.next
        }
        LogSenseLogger.debug("[ShareExt] Responder chain fallback failed")
        return false
    }
}
