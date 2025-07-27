import UIKit
import UniformTypeIdentifiers
import ImageIO

private let appGroupID = "group.logsense"

/// Returns the UserDefaults for the App Group if the container exists.
/// Falls back to `.standard` when unavailable to avoid runtime warnings.
private func groupDefaults() -> UserDefaults {
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil,
       let defaults = UserDefaults(suiteName: appGroupID) {
        return defaults
    }
    print("[ShareExt] App Group container missing; using UserDefaults.standard")
    return .standard
}

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[ShareExt] viewDidLoad")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("[ShareExt] viewDidAppear")
        handleShare()
    }

    private func handleShare() {
        print("[ShareExt] handleShare start")
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            print("[ShareExt] No input item")
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        // まず画像共有か確認
        if let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            print("[ShareExt] found image attachment")
            handleImage(provider: provider)
            return
        }

        print("[ShareExt] no image attachment, try extracting page info")

        extractPageInfo(from: item) { title, url in
            // App Group から取得。取得できない場合は標準の UserDefaults を使用
            let defaults = groupDefaults()
            let projectName = defaults.string(forKey: "ProjectName") ?? "YOUR_PROJECT"
            print("[ShareExt] projectName = \(projectName)")
            print("[ShareExt] received title = \(title)")
            print("[ShareExt] received url = \(url.absoluteString)")

            let scrapboxURL = self.makeScrapboxURL(project: projectName, title: title, link: url)
            print("[ShareExt] scrapboxURL (before encode) = \(scrapboxURL)")

            // Build callback URL safely with URLComponents
            var comps = URLComponents()
            comps.scheme = "logsense"
            comps.host = "open"
            comps.queryItems = [
                URLQueryItem(name: "scrapboxUrl", value: scrapboxURL)
            ]

            guard let callback = comps.url else {
                print("[ShareExt] Failed to build callback URL via URLComponents")
                self.extensionContext?.completeRequest(returningItems: nil)
                return
            }

            print("[ShareExt] callback url = \(callback.absoluteString)")
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.logsense") {
                print("[ShareExt] group container = \(containerURL.path)")
            } else {
                print("[ShareExt] group container NOT found")
            }
            print("[ShareExt] defaults(ProjectName)=\(defaults.string(forKey: "ProjectName") ?? "nil")")

            guard let context = self.extensionContext else {
                print("[ShareExt] extensionContext is nil")
                return
            }
            print("[ShareExt] opening main app")
            self.openCallback(callback, using: context)
        }
    }

    private func handleImage(provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
            DispatchQueue.main.async {
                print("[ShareExt] load data error=\(String(describing: error))")
                guard let data = data else {
                    print("[ShareExt] failed to load image data")
                    self.extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                print("[ShareExt] got raw image data size=\(data.count) bytes")


                let defaults = groupDefaults()

                let projectName = defaults.string(forKey: "ProjectName") ?? "YOUR_PROJECT"
                let token = defaults.string(forKey: "GyazoToken") ?? ""
                print("[ShareExt] project=\(projectName) token.isEmpty=\(token.isEmpty)")
                guard !token.isEmpty else {
                    self.extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                let date = self.exifDate(from: data) ?? self.currentDate()
                let (model, lens) = self.exifCameraInfo(from: data)

                let uploadData: Data
                if let jpg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    print("[ShareExt] converted image to JPEG size=\(jpg.count)")
                    uploadData = jpg
                } else {
                    print("[ShareExt] using original data for upload")
                    uploadData = data
                }

                self.uploadImage(data: uploadData, token: token) { urlString in

                    DispatchQueue.main.async {
                        guard let urlString = urlString else {
                            self.extensionContext?.completeRequest(returningItems: nil)
                            return
                        }

                        let scrapbox = self.makeScrapboxURLForImage(project: projectName,
                                                                    page: date,
                                                                    imageURL: urlString,
                                                                    camera: model,
                                                                    lens: lens)

                        var comps = URLComponents()
                        comps.scheme = "logsense"
                        comps.host = "open"
                        comps.queryItems = [URLQueryItem(name: "scrapboxUrl", value: scrapbox)]

                        guard let callback = comps.url else {
                            self.extensionContext?.completeRequest(returningItems: nil)
                            return
                        }

                        if let context = self.extensionContext {
                            self.openCallback(callback, using: context)
                        } else {
                            _ = self.openViaResponderChain(callback)
                            self.extensionContext?.completeRequest(returningItems: nil)
                        }
                    }
                }
            }
        }
    }

    private func exifDate(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            print("[ShareExt] no CGImageSource properties")
            return nil
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            print("[ShareExt] EXIF dict = \(exif)")
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String ??
                exif[kCGImagePropertyExifDateTimeDigitized] as? String {
                let result = String(dateStr.prefix(10)).replacingOccurrences(of: ":", with: "-")
                print("[ShareExt] exif date = \(result)")
                return result
            }
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            print("[ShareExt] TIFF dict = \(tiff)")
            if let dateStr = tiff[kCGImagePropertyTIFFDateTime] as? String {
                let result = String(dateStr.prefix(10)).replacingOccurrences(of: ":", with: "-")
                print("[ShareExt] tiff date = \(result)")
                return result
            }
        }

        print("[ShareExt] no exif date found")

        return nil
    }

    private func exifCameraInfo(from data: Data) -> (String?, String?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            print("[ShareExt] no CGImageSource properties for camera info")
            return (nil, nil)
        }

        var model: String?
        var lens: String?

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            model = tiff[kCGImagePropertyTIFFModel] as? String
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            lens = exif[kCGImagePropertyExifLensModel] as? String
        }

        print("[ShareExt] camera model=\(model ?? "nil") lens=\(lens ?? "nil")")
        return (model, lens)
    }

    private func currentDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func uploadImage(data: Data, token: String, completion: @escaping (String?) -> Void) {
        let boundary = UUID().uuidString
        var req = URLRequest(url: URL(string: "https://upload.gyazo.com/api/upload")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"access_token\"\r\n\r\n")
        append("\(token)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"imagedata\"; filename=\"image.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(data)
        append("\r\n")
        append("--\(boundary)--\r\n")

        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                print("[ShareExt] upload error=\(error.localizedDescription)")
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                print("[ShareExt] upload failed to parse response")
                completion(nil)
                return
            }
            print("[ShareExt] upload success URL=\(url)")
            completion(url)
        }.resume()
    }

    private func makeScrapboxURLForImage(project: String,
                                         page: String,
                                         imageURL: String,
                                         camera: String?,
                                         lens: String?) -> String {
        let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encTitle = page.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? page

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

        let encBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        return "https://scrapbox.io/\(project)/\(encTitle)?body=\(encBody)"
    }

    private func extractPageInfo(from item: NSExtensionItem,
                                 completion: @escaping (String, URL) -> Void) {

        let providers = item.attachments ?? []
        print("[ShareExt] extractPageInfo providers count=\(providers.count)")
        guard !providers.isEmpty else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        // 1) URL を最優先で取得
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            print("[ShareExt] found URL provider")
            provider.loadObject(ofClass: URL.self) { (url, error) in
                DispatchQueue.main.async {
                    print("[ShareExt] load URL error=\(String(describing: error))")
                    guard let url = url else {
                        print("[ShareExt] URL provider returned nil")
                        self.extensionContext?.completeRequest(returningItems: nil)
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
            print("[ShareExt] found String provider")
            provider.loadObject(ofClass: String.self) { (text, error) in
                DispatchQueue.main.async {
                    print("[ShareExt] load String error=\(String(describing: error))")
                    let rawText = text ?? ""
                    if let firstURL = URL(string: rawText) {
                        completion(rawText, firstURL)
                    } else {
                        print("[ShareExt] String provider text did not contain URL")
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
            return
        }

        // 3) どちらも取得できない場合は終了
        print("[ShareExt] extractPageInfo no suitable provider")
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func makeScrapboxURL(project: String, title: String, link: URL) -> String {
        // Scrapboxのパス部分 & URL 部分ともにスラッシュを含めて厳密にエンコードする
        let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

        // title がURLでもスラッシュが残らないよう同じルールでエンコード
        let encTitle = title.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? title

        // link は既に URL 型なので absoluteString を同じルールで
        let encLink = link.absoluteString.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? link.absoluteString

        print("[ShareExt] encTitle=\(encTitle)")
        print("[ShareExt] encLink=\(encLink)")

        let body = "[\(title) \(encLink)]"
        let encBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        return "https://scrapbox.io/\(project)/\(encTitle)?body=\(encBody)"
    }

    /// Attempts to open the main application with the given callback URL.
    /// Uses `extensionContext.open` and falls back to the responder chain.
    private func openCallback(_ url: URL, using context: NSExtensionContext) {
        context.open(url) { success in
            print("[ShareExt] context.open success = \(success)")
            if !success {
                _ = self.openViaResponderChain(url)
            }
            context.completeRequest(returningItems: nil)
        }
    }

    @discardableResult
    private func openViaResponderChain(_ url: URL) -> Bool {
        print("[ShareExt] trying responder chain fallback")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                // Prefer modern API
                if app.responds(to: #selector(UIApplication.open(_:options:completionHandler:))) {
                    app.open(url, options: [:]) { success in
                        print("[ShareExt] Fallback UIApplication.open success = \(success)")
                    }
                    return true
                }
                // Legacy fallback (should not be used on modern iOS, but kept just in case)
                let sel = NSSelectorFromString("openURL:")
                if app.responds(to: sel) {
                    app.perform(sel, with: url)
                    print("[ShareExt] Fallback openURL via responder chain (legacy)")
                    return true
                }
            }
            responder = r.next
        }
        print("[ShareExt] Responder chain fallback failed")
        return false
    }
}
