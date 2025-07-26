import UIKit
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleShare()
    }

    private func handleShare() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        // まず画像共有か確認
        if let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            handleImage(provider: provider)
            return
        }

        extractPageInfo(from: item) { title, url in
            // App Group から取得（なければ固定名にフォールバック）
            guard let defaults = UserDefaults(suiteName: "group.logsense") else {
                print("[ShareExt] App Group defaults is nil. Check entitlements/group ID.")
                self.extensionContext?.completeRequest(returningItems: nil)
                return
            }
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

            // 先に開いてから completeRequest の順で試す
            context.open(callback) { success in
                print("[ShareExt] context.open success = \(success)")
                if !success {
                    _ = self.openViaResponderChain(callback)
                }
                // open の成否に関わらず完了させる
                context.completeRequest(returningItems: nil)
            }
        }
    }

    private func handleImage(provider: NSItemProvider) {
        provider.loadObject(ofClass: UIImage.self) { image, error in
            DispatchQueue.main.async {
                guard let uiImage = image as? UIImage,
                      let data = uiImage.jpegData(compressionQuality: 0.9) else {
                    self.extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                guard let defaults = UserDefaults(suiteName: "group.logsense") else {
                    self.extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                let projectName = defaults.string(forKey: "ProjectName") ?? "YOUR_PROJECT"
                let token = defaults.string(forKey: "GyazoToken") ?? ""
                guard !token.isEmpty else {
                    self.extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                let date = self.exifDate(from: data) ?? self.currentDate()

                self.uploadImage(data: data, token: token) { urlString in
                    DispatchQueue.main.async {
                        guard let urlString = urlString else {
                            self.extensionContext?.completeRequest(returningItems: nil)
                            return
                        }

                        let scrapbox = self.makeScrapboxURLForImage(project: projectName, page: date, imageURL: urlString)

                        var comps = URLComponents()
                        comps.scheme = "logsense"
                        comps.host = "open"
                        comps.queryItems = [URLQueryItem(name: "scrapboxUrl", value: scrapbox)]

                        guard let callback = comps.url else {
                            self.extensionContext?.completeRequest(returningItems: nil)
                            return
                        }

                        self.extensionContext?.open(callback) { _ in
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
            return nil
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            return String(dateStr.prefix(10)).replacingOccurrences(of: ":", with: "-")
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateStr = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return String(dateStr.prefix(10)).replacingOccurrences(of: ":", with: "-")
        }
        return nil
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
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                completion(nil)
                return
            }
            completion(url)
        }.resume()
    }

    private func makeScrapboxURLForImage(project: String, page: String, imageURL: String) -> String {
        let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encTitle = page.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? page
        let body = "[\(imageURL)]"
        let encBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        return "https://scrapbox.io/\(project)/\(encTitle)?body=\(encBody)"
    }

    private func extractPageInfo(from item: NSExtensionItem,
                                 completion: @escaping (String, URL) -> Void) {

        let providers = item.attachments ?? []
        guard !providers.isEmpty else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        // 1) URL を最優先で取得
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            provider.loadObject(ofClass: URL.self) { (url, error) in
                DispatchQueue.main.async {
                    guard let url = url else {
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
            provider.loadObject(ofClass: String.self) { (text, error) in
                DispatchQueue.main.async {
                    let rawText = text ?? ""
                    if let firstURL = URL(string: rawText) {
                        completion(rawText, firstURL)
                    } else {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
            return
        }

        // 3) どちらも取得できない場合は終了
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

    @discardableResult
    private func openViaResponderChain(_ url: URL) -> Bool {
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
