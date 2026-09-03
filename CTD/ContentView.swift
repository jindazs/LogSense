import SwiftUI
import WebKit

struct UserDefaultsKeys {
    static let projectName = "ProjectName"
    static let photoProjectName = "PhotoProjectName"
}
let appGroupID = "group.logsense"

/// Returns the shared UserDefaults stored in the App Group if available.
/// Falls back to `.standard` and prints a warning when the group container is
/// missing so the app can still launch without crashing.
func sharedDefaults() -> UserDefaults {
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil,
       let defaults = UserDefaults(suiteName: appGroupID) {
        return defaults
    }
    LogSenseLogger.debug("[LogSense] App Group container missing; using UserDefaults.standard")
    return .standard
}

let groupDefaults = sharedDefaults()

enum AppTab {
    case todo
    case home
    case today
    case photos
}

final class WebViewModel: ObservableObject {
    private var webView: CustomWebView?
    private var initialURL: URL
    private var pendingURL: URL?

    var isWebViewCreated: Bool {
        webView != nil
    }

    init(url: URL) {
        self.initialURL = url
    }

    func webViewForDisplay() -> CustomWebView {
        if let webView {
            return webView
        }

        let webView = CustomWebView()
        let url = pendingURL ?? initialURL
        pendingURL = nil
        webView.load(URLRequest(url: url))
        self.webView = webView
        return webView
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func resetToInitialPage() {
        webView?.stopLoading()
        if let webView {
            webView.load(URLRequest(url: initialURL))
        } else {
            pendingURL = nil
        }
    }

    func updateInitialURL(_ url: URL) {
        initialURL = url
        pendingURL = nil
        webView?.load(URLRequest(url: url))
    }

    func loadURL(_ url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            pendingURL = url
        }
    }

    func loadURLsSequentially(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        guard let first = urls.first else {
            completion(true)
            return
        }
        let webView = webViewForDisplay()
        webView.stopLoading()
        webView.loadURL(first) { [weak self] success in
            guard success else {
                completion(false)
                return
            }
            self?.loadURLsSequentially(Array(urls.dropFirst()), completion: completion)
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var projectName: String = groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? ""
    @State private var photoProjectName: String = groupDefaults.string(
        forKey: UserDefaultsKeys.photoProjectName
    ) ?? SharedSettingsKeys.defaultPhotoProjectName
    @State private var gyazoToken: String = GyazoTokenStore.load(migratingFrom: groupDefaults)
    @State private var showSettings: Bool = false
    @State private var showPhotoQueue: Bool = false
    @State private var settingsDidSave: Bool = false
    @State private var selectedTab: AppTab = .home
    @State private var currentDate = ""
    @StateObject private var photoImportCoordinator = PhotoImportCoordinator()

    @StateObject private var mainWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )
    @StateObject private var todoWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")/ToDo")!
    )
    @StateObject private var dateWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )
    @StateObject private var photoWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.photoProjectName) ?? SharedSettingsKeys.defaultPhotoProjectName)")!
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            if selectedTab == .todo {
                WebViewWrapper(webViewModel: todoWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if selectedTab == .home {
                WebViewWrapper(webViewModel: mainWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if selectedTab == .today {
                WebViewWrapper(webViewModel: dateWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if selectedTab == .photos {
                WebViewWrapper(webViewModel: photoWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            }

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.8))
                    .shadow(radius: 5)
                    .frame(height: 50)
                HStack {
                    Spacer()
                    // 以下は元のHStack内の3つのButton定義をそのまま貼り付け
                    Button(action: {
                        selectedTab = .todo
                    }) {
                        Image(systemName: "list.bullet")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == .todo ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        todoWebViewModel.resetToInitialPage()
                    }
                    Spacer()
                    Button(action: {
                        selectedTab = .home
                    }) {
                        Image(systemName: "house.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == .home ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        mainWebViewModel.resetToInitialPage()
                    }
                    .onTapGesture(count: 3) {
                        settingsDidSave = false
                        showSettings = true
                    }
                    Spacer()
                    Button(action: {
                        selectedTab = .today
                    }) {
                        Image(systemName: "calendar")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == .today ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        currentDate = getCurrentDate()
                        let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
                        dateWebViewModel.loadURL(dateUrl)
                    }
                    .onTapGesture(count: 3) {
                        let year = Calendar.current.component(.year, from: Date())
                        let yearString = "\(year)年"
                        if let url = URL(string: "https://scrapbox.io/\(projectName)/\(yearString)") {
                            dateWebViewModel.loadURL(url)
                        }
                    }
                    Spacer()
                    Button(action: {
                        selectedTab = .photos
                    }) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == .photos ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        photoWebViewModel.resetToInitialPage()
                    }
                    Spacer()
                    Button(action: {
                        photoImportCoordinator.refreshQueue()
                        showPhotoQueue = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12.5, height: 12.5)
                                .padding(8)
                                .background(Circle().fill(Color.white.opacity(0.9)))
                                .shadow(radius: 4)
                            if !photoImportCoordinator.pendingBatches.isEmpty {
                                Text("\(photoImportCoordinator.pendingBatches.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.red))
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .accessibilityLabel("写真アップロードキュー")
                    Spacer()
                }
            }
            .padding(.bottom, 8)

            if photoImportCoordinator.isPresented {
                PhotoImportProgressView(coordinator: photoImportCoordinator)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
            }
        }
        .onAppear {
            projectName = groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? ""
            photoProjectName = groupDefaults.string(forKey: UserDefaultsKeys.photoProjectName)
                ?? SharedSettingsKeys.defaultPhotoProjectName
            currentDate = getCurrentDate()
            let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
            dateWebViewModel.updateInitialURL(dateUrl)
            let photoURL = URL(string: "https://scrapbox.io/\(photoProjectName)")!
            photoWebViewModel.updateInitialURL(photoURL)
            photoImportCoordinator.refreshQueue()
            if !photoImportCoordinator.isPresented,
               let pending = try? PhotoImportStore.shared().pendingBatches().first {
                beginPhotoImport(batchID: pending.id)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if settingsDidSave {
                applyProjectName()
            }
        }) {
            SettingsView(
                projectName: $projectName,
                photoProjectName: $photoProjectName,
                gyazoToken: $gyazoToken,
                onSave: { settingsDidSave = true }
            )
        }
        .sheet(isPresented: $showPhotoQueue) {
            PhotoImportQueueView(coordinator: photoImportCoordinator) { batchID in
                beginPhotoImport(batchID: batchID)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                photoImportCoordinator.pause()
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    private func applyProjectName() {
        let mainURL = URL(string: "https://scrapbox.io/\(projectName)")!
        mainWebViewModel.updateInitialURL(mainURL)

        let todoURL = URL(string: "https://scrapbox.io/\(projectName)/ToDo")!
        todoWebViewModel.updateInitialURL(todoURL)

        let dateURL = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
        dateWebViewModel.updateInitialURL(dateURL)

        let photoURL = URL(string: "https://scrapbox.io/\(photoProjectName)")!
        photoWebViewModel.updateInitialURL(photoURL)
    }

    func getCurrentDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: Date())
    }

    private func handleIncomingURL(_ url: URL) {
        LogSenseLogger.debug("[LogSense] handleIncomingURL \(url.absoluteString)")
        guard url.scheme == "logsense" else {
            LogSenseLogger.debug("[LogSense] invalid scheme or host")
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "import-photos" {
            guard let value = components?.queryItems?.first(where: { $0.name == "batchID" })?.value,
                  let batchID = UUID(uuidString: value) else {
                LogSenseLogger.debug("[LogSense] invalid photo batch ID")
                return
            }
            beginPhotoImport(batchID: batchID)
            return
        }

        guard url.host == "open" else {
            LogSenseLogger.debug("[LogSense] invalid host")
            return
        }

        let scrapParam = components?.queryItems?.first(where: { $0.name == "scrapboxUrl" })?.value
        LogSenseLogger.debug("[LogSense] scrapParam=\(scrapParam ?? "nil")")

        guard let encoded = scrapParam,
              let targetURL = URL(string: encoded),
              WebURLPolicy.isAllowedContentURL(targetURL) else {
            LogSenseLogger.debug("[LogSense] rejected untrusted target URL")
            return
        }
        LogSenseLogger.debug("[LogSense] targetURL = \(targetURL)")

        // Switch to main tab and load the page
        selectedTab = .home
        mainWebViewModel.loadURL(targetURL)
        LogSenseLogger.debug("[LogSense] loaded URL in main web view")
    }

    private func beginPhotoImport(batchID: UUID) {
        do {
            let batch = try PhotoImportStore.shared().load(batchID)
            selectedTab = batch.destination == .photo ? .photos : .home
            let targetWebView = batch.destination == .photo ? photoWebViewModel : mainWebViewModel
            photoImportCoordinator.start(
                batchID: batchID,
                token: GyazoTokenStore.load(migratingFrom: groupDefaults)
            ) { appends, completion in
                let urls = appends.compactMap {
                    ScrapboxURLBuilder.makePageURL(
                        project: batch.projectName,
                        title: $0.pageTitle,
                        body: $0.body
                    )
                }
                guard urls.count == appends.count else {
                    completion(false)
                    return
                }
                targetWebView.loadURLsSequentially(urls, completion: completion)
            }
        } catch {
            LogSenseLogger.debug("[LogSense] photo batch load failed: \(error.localizedDescription)")
        }
    }
}

class CustomWebView: WKWebView, WKNavigationDelegate {
    private var loadCompletion: ((Bool) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        self.allowsBackForwardNavigationGestures = true
        self.navigationDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadURL(_ url: URL, completion: @escaping (Bool) -> Void) {
        loadCompletion = completion
        load(URLRequest(url: url))
    }

    // -----------------------------
    // ここからが「Today」ボタンと「Done」ボタンの実装
    // -----------------------------
    private lazy var cachedInputAccessoryView: UIView = makeInputAccessoryView()

    override var inputAccessoryView: UIView? {
        cachedInputAccessoryView
    }

    private func makeInputAccessoryView() -> UIView {
        let accessoryView = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 40))
        accessoryView.backgroundColor = UIColor.systemGray5
        accessoryView.autoresizingMask = [.flexibleWidth]

        let buttonStack = UIStackView()
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let dateButton = UIButton(type: .system)
        dateButton.setTitle("Today", for: .normal)
        dateButton.addTarget(self, action: #selector(insertDate), for: .touchUpInside)

        let dismissButton = UIButton(type: .system)
        dismissButton.setTitle("Done", for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)

        buttonStack.addArrangedSubview(dateButton)
        buttonStack.addArrangedSubview(dismissButton)
        accessoryView.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor)
        ])

        return accessoryView
    }

    // 「Today」ボタンが押されたときに、日付テキストを挿入
    @objc func insertDate() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M月d日"
        let dateString = "#\(dateFormatter.string(from: Date()))"

        // テキストエリアに直接文字を注入
        let script = "document.execCommand('insertText', false, '\(dateString)');"
        self.evaluateJavaScript(script, completionHandler: nil)
    }

    // 「Today」ボタンのトリプルタップで今年("YYYY年")のページを開く
    @objc func openYearPage() {
        let project = groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? ""
        let year = Calendar.current.component(.year, from: Date())
        // 「YYYY年」の形式にしてページを開く
        let yearString = "\(year)年"
        if let url = URL(string: "https://scrapbox.io/\(project)/\(yearString)") {
            let request = URLRequest(url: url)
            self.load(request)
        }
    }

    // 「Done」ボタンでキーボードを閉じる
    @objc func dismissKeyboard() {
        let script = "document.activeElement.blur();"
        self.evaluateJavaScript(script) { _, error in
            if let error = error {
                LogSenseLogger.debug("Failed to dismiss keyboard: \(error.localizedDescription)")
            }
        }
    }
    // -----------------------------
    // ここまでがキーボード上のボタン実装
    // -----------------------------

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if WebURLPolicy.isAllowedInAppURL(url) {
            decisionHandler(.allow)
            return
        }

        if url.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        // Subframe navigation must not launch another application.
        guard navigationAction.targetFrame?.isMainFrame != false,
              UIApplication.shared.canOpenURL(url) else {
            return
        }

        // Open untrusted or non-web destinations outside the embedded WebView.
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let completion = loadCompletion
        loadCompletion = nil
        completion?(true)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let completion = loadCompletion
        loadCompletion = nil
        completion?(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let completion = loadCompletion
        loadCompletion = nil
        completion?(false)
    }

}

struct WebViewWrapper: UIViewRepresentable {
    @ObservedObject var webViewModel: WebViewModel

    func makeUIView(context: Context) -> CustomWebView {
        webViewModel.webViewForDisplay()
    }

    func updateUIView(_ uiView: CustomWebView, context: Context) {
        // 既存のWebViewを使うので更新処理は不要
    }
}

struct SettingsView: View {
    @Binding var projectName: String
    @Binding var photoProjectName: String
    @Binding var gyazoToken: String
    @Environment(\.presentationMode) var presentationMode
    @State private var draftProjectName: String
    @State private var draftPhotoProjectName: String
    @State private var draftGyazoToken: String
    @State private var saveErrorMessage: String?
    let onSave: () -> Void

    init(
        projectName: Binding<String>,
        photoProjectName: Binding<String>,
        gyazoToken: Binding<String>,
        onSave: @escaping () -> Void
    ) {
        _projectName = projectName
        _photoProjectName = photoProjectName
        _gyazoToken = gyazoToken
        _draftProjectName = State(initialValue: projectName.wrappedValue)
        _draftPhotoProjectName = State(initialValue: photoProjectName.wrappedValue)
        _draftGyazoToken = State(initialValue: gyazoToken.wrappedValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("プロジェクト名")) {
                    TextField("プロジェクト名", text: $draftProjectName)
                }
                Section(header: Text("写真プロジェクト名")) {
                    TextField("写真プロジェクト名", text: $draftPhotoProjectName)
                }
                Section(header: Text("Gyazo Token")) {
                    SecureField("access token", text: $draftGyazoToken)
                }
            }
            .navigationBarItems(trailing: Button("保存") {
                let normalizedProjectName = draftProjectName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedGyazoToken = draftGyazoToken
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedPhotoProjectName = draftPhotoProjectName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedProjectName.isEmpty else {
                    saveErrorMessage = "プロジェクト名を入力してください。"
                    return
                }
                guard !normalizedPhotoProjectName.isEmpty else {
                    saveErrorMessage = "写真プロジェクト名を入力してください。"
                    return
                }
                guard normalizedProjectName != normalizedPhotoProjectName else {
                    saveErrorMessage = "メインと写真には異なるプロジェクトを指定してください。"
                    return
                }

                do {
                    try GyazoTokenStore.save(
                        normalizedGyazoToken,
                        removingLegacyValueFrom: groupDefaults
                    )
                    groupDefaults.set(normalizedProjectName, forKey: UserDefaultsKeys.projectName)
                    groupDefaults.set(normalizedPhotoProjectName, forKey: UserDefaultsKeys.photoProjectName)
                    projectName = normalizedProjectName
                    photoProjectName = normalizedPhotoProjectName
                    gyazoToken = normalizedGyazoToken
                    onSave()
                    presentationMode.wrappedValue.dismiss()
                } catch {
                    saveErrorMessage = error.localizedDescription
                }
            })
            .alert("保存できませんでした", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }
}

struct PhotoImportProgressView: View {
    @ObservedObject var coordinator: PhotoImportCoordinator
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 12) {
            Text(coordinator.statusMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
            ProgressView(value: coordinator.progress)
                .progressViewStyle(.linear)
            if let batch = coordinator.batch {
                Text("\(batch.uploadedCount + batch.failedCount) / \(batch.items.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if coordinator.canPause {
                Button("一時停止") {
                    coordinator.pause()
                }
                .buttonStyle(.borderedProminent)
            }
            if coordinator.canResume || coordinator.canRetry || coordinator.canCommitSuccesses {
                HStack {
                    if coordinator.canResume {
                        Button("再開") {
                            coordinator.resume()
                        }
                    }
                    if coordinator.canRetry {
                        Button("失敗分を再試行") {
                            coordinator.retryFailedItems()
                        }
                    }
                    if coordinator.canCommitSuccesses {
                        Button("成功分だけ追加") {
                            coordinator.commitSuccessfulItems()
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            if !coordinator.isWorking {
                HStack {
                    Button("閉じる") {
                        coordinator.close()
                    }
                    if coordinator.canDiscard {
                        Button("破棄", role: .destructive) {
                            confirmDiscard = true
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8)
        .confirmationDialog(
            "このアップロードを破棄しますか？",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("画像と進捗を削除", role: .destructive) {
                coordinator.discardCurrentBatch()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

struct PhotoImportQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: PhotoImportCoordinator
    let onSelect: (UUID) -> Void
    @State private var batchToDelete: PhotoImportBatch?

    var body: some View {
        NavigationView {
            Group {
                if coordinator.pendingBatches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("未完了のアップロードはありません")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(coordinator.pendingBatches) { batch in
                        HStack {
                            Button {
                                dismiss()
                                onSelect(batch.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(batch.projectName)
                                        .font(.headline)
                                    Text(queueDescription(for: batch))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if coordinator.batch?.id == batch.id && coordinator.isWorking {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(coordinator.isWorking && coordinator.batch?.id != batch.id)

                            if !coordinator.isWorking || coordinator.batch?.id != batch.id {
                                Button(role: .destructive) {
                                    batchToDelete = batch
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("写真アップロード")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onAppear { coordinator.refreshQueue() }
        .alert(item: $batchToDelete) { batch in
            Alert(
                title: Text("アップロードを破棄しますか？"),
                message: Text("保存済みの画像と進捗を削除します。"),
                primaryButton: .destructive(Text("破棄")) {
                    coordinator.discard(batchID: batch.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func queueDescription(for batch: PhotoImportBatch) -> String {
        let state: String
        switch batch.state {
        case .staging: state = "取り込み中断"
        case .staged: state = "待機中"
        case .uploading: state = "アップロード中"
        case .paused: state = "一時停止"
        case .awaitingDecision: state = "確認待ち"
        case .committing: state = "Cosenseへ追加中"
        case .commitUncertain: state = "追加結果の確認が必要"
        case .completed: state = "完了"
        case .failed: state = "失敗"
        }
        return "\(batch.uploadedCount + batch.failedCount) / \(batch.items.count)枚・\(state)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
