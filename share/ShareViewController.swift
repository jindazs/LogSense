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

final class ShareViewController: UIViewController {
    private var hasStartedHandlingShare = false
    private var isShowingError = false
    private var stagingProgress: Progress?
    private var stagingAlert: UIAlertController?
    private var stagingBatchID: UUID?
    private var stagingStore: PhotoImportStore?
    private let stagingStateLock = NSLock()
    private var stagingWasCancelled = false
    private var destinationPickerContainer: UIView?
    private var destinationPickerCard: UIView?

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
        let imageProviders = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) } ?? []
        if !imageProviders.isEmpty {
            LogSenseLogger.debug("[ShareExt] found \(imageProviders.count) image attachments")
            guard imageProviders.count <= 20 else {
                presentError("一度に共有できる写真は20枚までです。")
                return
            }
            presentPhotoDestinationPicker(providers: imageProviders)
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

    private func presentPhotoDestinationPicker(providers: [NSItemProvider]) {
        let defaults = groupDefaults()
        let primaryProject = defaults.string(forKey: SharedSettingsKeys.primaryProjectName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuredPhotoProject = defaults.string(forKey: SharedSettingsKeys.photoProjectName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let photoProject = configuredPhotoProject.isEmpty
            ? SharedSettingsKeys.defaultPhotoProjectName
            : configuredPhotoProject

        guard !primaryProject.isEmpty else {
            presentError("先にLogSenseの設定画面でプロジェクト名を設定してください。")
            return
        }
        guard !GyazoTokenStore.load(migratingFrom: defaults).isEmpty else {
            presentError("先にLogSenseの設定画面でGyazo Tokenを設定してください。")
            return
        }

        DispatchQueue.main.async {
            self.showPhotoDestinationPicker(
                photoCount: providers.count,
                primaryProject: primaryProject,
                photoProject: photoProject,
                onPrimary: { [weak self] in
                    self?.stageImages(
                        providers: providers,
                        destination: .primary,
                        projectName: primaryProject
                    )
                },
                onPhoto: { [weak self] in
                    self?.stageImages(
                        providers: providers,
                        destination: .photo,
                        projectName: photoProject
                    )
                }
            )
        }
    }

    private func showPhotoDestinationPicker(
        photoCount: Int,
        primaryProject: String,
        photoProject: String,
        onPrimary: @escaping () -> Void,
        onPhoto: @escaping () -> Void
    ) {
        destinationPickerContainer?.removeFromSuperview()

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.18)

        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor

        let cardShadow = UIView()
        cardShadow.translatesAutoresizingMaskIntoConstraints = false
        cardShadow.backgroundColor = .clear
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.24
        cardShadow.layer.shadowRadius = 24
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 12)

        let icon = UIImageView(image: UIImage(systemName: "photo.stack.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)

        let iconBackground = UIView()
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        iconBackground.layer.cornerRadius = 24
        iconBackground.addSubview(icon)

        let titleLabel = UILabel()
        titleLabel.text = "写真の共有先"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        let countText = photoCount == 1 ? "1枚の写真" : "\(photoCount)枚の写真"
        let messageLabel = UILabel()
        messageLabel.text = "\(countText)を取り込む場所を選択してください"
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let primaryButton = makeDestinationButton(
            title: "メイン",
            projectName: primaryProject,
            symbolName: "house.fill",
            color: .systemBlue
        ) { [weak self] in
            self?.dismissDestinationPicker(completion: onPrimary)
        }

        let photoButton = makeDestinationButton(
            title: "写真",
            projectName: photoProject,
            symbolName: "photo.on.rectangle.angled",
            color: .systemIndigo
        ) { [weak self] in
            self?.dismissDestinationPicker(completion: onPhoto)
        }

        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = "キャンセル"
        cancelConfiguration.baseForegroundColor = .secondaryLabel
        let cancelButton = UIButton(configuration: cancelConfiguration)
        cancelButton.addAction(UIAction { [weak self] _ in
            self?.dismissDestinationPicker {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }, for: .touchUpInside)
        cancelButton.accessibilityHint = "写真の共有を中止します"

        let stack = UIStackView(arrangedSubviews: [
            iconBackground,
            titleLabel,
            messageLabel,
            primaryButton,
            photoButton,
            cancelButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(24, after: messageLabel)
        stack.setCustomSpacing(8, after: primaryButton)

        view.addSubview(container)
        container.addSubview(cardShadow)
        cardShadow.addSubview(card)
        card.contentView.addSubview(stack)

        let preferredCardWidth = cardShadow.widthAnchor.constraint(
            equalTo: container.widthAnchor,
            constant: -40
        )
        preferredCardWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardShadow.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            cardShadow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            cardShadow.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            cardShadow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            cardShadow.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            preferredCardWidth,

            card.leadingAnchor.constraint(equalTo: cardShadow.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardShadow.trailingAnchor),
            card.topAnchor.constraint(equalTo: cardShadow.topAnchor),
            card.bottomAnchor.constraint(equalTo: cardShadow.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14),

            iconBackground.widthAnchor.constraint(equalToConstant: 48),
            iconBackground.heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: iconBackground.leadingAnchor, constant: 12),
            icon.trailingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: -12),
            icon.topAnchor.constraint(equalTo: iconBackground.topAnchor, constant: 12),
            icon.bottomAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: -12),
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            photoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        destinationPickerContainer = container
        destinationPickerCard = cardShadow
        container.alpha = 0
        cardShadow.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: [.curveEaseOut]
        ) {
            container.alpha = 1
            cardShadow.transform = .identity
        }
    }

    private func makeDestinationButton(
        title: String,
        projectName: String,
        symbolName: String,
        color: UIColor,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.subtitle = projectName
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 14
        configuration.titleAlignment = .leading
        configuration.cornerStyle = .large
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.accessibilityLabel = "\(title)、\(projectName)"
        button.accessibilityHint = "このプロジェクトへ写真を取り込みます"
        return button
    }

    private func dismissDestinationPicker(completion: @escaping () -> Void) {
        guard let container = destinationPickerContainer else {
            completion()
            return
        }
        let card = destinationPickerCard
        destinationPickerContainer = nil
        destinationPickerCard = nil
        UIView.animate(withDuration: 0.16, animations: {
            container.alpha = 0
            card?.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.98, y: 0.98)
        }) { _ in
            container.removeFromSuperview()
            completion()
        }
    }

    private func stageImages(
        providers: [NSItemProvider],
        destination: PhotoImportDestination,
        projectName: String
    ) {
        let batchID = UUID()
        do {
            let store = try PhotoImportStore.shared()
            _ = try store.createDirectory(for: batchID)
            let batch = PhotoImportBatch(
                id: batchID,
                destination: destination,
                projectName: projectName,
                createdAt: Date(),
                items: [],
                state: .staging
            )
            try store.save(batch)
            stagingStateLock.lock()
            stagingWasCancelled = false
            stagingStateLock.unlock()
            stagingBatchID = batchID
            stagingStore = store
            presentStagingProgress(completed: 0, total: providers.count)
            loadAndStageImage(
                at: 0,
                providers: providers,
                batchID: batchID,
                destination: destination,
                projectName: projectName,
                store: store
            )
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func loadAndStageImage(
        at index: Int,
        providers: [NSItemProvider],
        batchID: UUID,
        destination: PhotoImportDestination,
        projectName: String,
        store: PhotoImportStore
    ) {
        guard !isStagingCancelled else { return }
        guard index < providers.count else {
            do {
                var batch = try store.load(batchID)
                batch.state = .staged
                try store.save(batch)
                DispatchQueue.main.async {
                    let openApp = {
                        self.stagingAlert = nil
                        self.openPhotoImport(batchID: batchID)
                    }
                    if let alert = self.stagingAlert {
                        alert.dismiss(animated: true, completion: openApp)
                    } else {
                        openApp()
                    }
                }
            } catch {
                try? store.remove(batchID)
                presentError(error.localizedDescription)
            }
            return
        }

        let provider = providers[index]
        let originalFilename = provider.suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier
        stagingProgress = provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self] sourceURL, error in
            guard let self else { return }
            self.stagingStateLock.lock()
            guard !self.stagingWasCancelled else {
                self.stagingStateLock.unlock()
                return
            }
            defer { self.stagingStateLock.unlock() }
            guard let sourceURL else {
                LogSenseLogger.debug("[ShareExt] image \(index) load error=\(String(describing: error))")
                try? store.remove(batchID)
                self.presentError("\(index + 1)枚目の画像を読み込めませんでした。")
                return
            }

            autoreleasepool {
                let storedOriginalFilename = originalFilename?.isEmpty == false
                    ? originalFilename
                    : sourceURL.lastPathComponent
                let typeExtension = UTType(typeIdentifier)?.preferredFilenameExtension
                let sourceExtension = sourceURL.pathExtension.isEmpty ? nil : sourceURL.pathExtension
                let fileExtension = typeExtension ?? sourceExtension ?? "image"
                let filename = String(format: "%03d-%@.%@", index, UUID().uuidString, fileExtension)
                let fileURL = store.imageURL(batchID: batchID, filename: filename)
                let partialURL = fileURL.appendingPathExtension("partial")
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: partialURL)
                    try FileManager.default.moveItem(at: partialURL, to: fileURL)
                    let metadata = ImageMetadataReader.read(from: fileURL)
                    let fingerprint = try ImageFingerprint.make(from: fileURL)
                    let historyStore = try PhotoUploadHistoryStore.shared()
                    var batch = try store.load(batchID)
                    let isDuplicate = batch.items.contains {
                        $0.contentHash == fingerprint.sha256
                    } || historyStore.record(for: fingerprint.sha256) != nil
                    batch.items.append(PhotoImportItem(
                        id: UUID(),
                        originalIndex: index,
                        localFilename: filename,
                        capturedDate: metadata.date ?? self.currentDate(),
                        camera: metadata.cameraModel,
                        lens: metadata.lensModel,
                        originalFilename: storedOriginalFilename,
                        byteSize: fingerprint.byteSize,
                        contentHash: fingerprint.sha256,
                        state: isDuplicate ? .skipped : .staged,
                        gyazoURL: nil,
                        attemptCount: 0,
                        errorMessage: nil
                    ))
                    try store.save(batch)
                    if isDuplicate {
                        try? FileManager.default.removeItem(at: fileURL)
                        LogSenseLogger.debug("[ShareExt] skipped duplicate image \(index)")
                    }
                } catch {
                    try? FileManager.default.removeItem(at: partialURL)
                    try? store.remove(batchID)
                    guard !self.isStagingCancelled else { return }
                    self.presentError("\(index + 1)枚目の画像を保存できませんでした。")
                    return
                }

                DispatchQueue.main.async {
                    self.presentStagingProgress(completed: index + 1, total: providers.count)
                    self.loadAndStageImage(
                        at: index + 1,
                        providers: providers,
                        batchID: batchID,
                        destination: destination,
                        projectName: projectName,
                        store: store
                    )
                }
            }
        }
    }

    private var isStagingCancelled: Bool {
        stagingStateLock.lock()
        defer { stagingStateLock.unlock() }
        return stagingWasCancelled
    }

    private func presentStagingProgress(completed: Int, total: Int) {
        DispatchQueue.main.async {
            if let alert = self.stagingAlert {
                alert.message = "\(completed) / \(total)枚を保存しました。"
                return
            }
            let alert = UIAlertController(
                title: "写真を取り込み中",
                message: "\(completed) / \(total)枚を保存しました。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "キャンセル", style: .destructive) { _ in
                self.cancelStaging()
            })
            self.stagingAlert = alert
            self.present(alert, animated: true)
        }
    }

    private func cancelStaging() {
        stagingStateLock.lock()
        stagingWasCancelled = true
        stagingStateLock.unlock()
        stagingProgress?.cancel()
        if let batchID = stagingBatchID {
            try? stagingStore?.remove(batchID)
        }
        stagingAlert = nil
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func openPhotoImport(batchID: UUID) {
        var components = URLComponents()
        components.scheme = "logsense"
        components.host = "import-photos"
        components.queryItems = [URLQueryItem(name: "batchID", value: batchID.uuidString)]
        guard let callback = components.url, let context = extensionContext else {
            presentError("LogSenseを開くためのURLを作成できませんでした。")
            return
        }
        openCallback(callback, using: context)
    }

    private func currentDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
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
            let showError = {
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
            if let stagingAlert = self.stagingAlert {
                self.stagingAlert = nil
                stagingAlert.dismiss(animated: true, completion: showError)
            } else {
                showError()
            }
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
