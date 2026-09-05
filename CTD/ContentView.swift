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

enum AppTab: CaseIterable {
    case home
    case today
    case todo
    case photos

    var title: String {
        switch self {
        case .todo: return "ToDo"
        case .home: return "Home"
        case .today: return "Today"
        case .photos: return "Photos"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: return "list.bullet"
        case .home: return "house"
        case .today: return "calendar"
        case .photos: return "photo.on.rectangle"
        }
    }

    var selectedSymbolName: String {
        switch self {
        case .todo: return "list.bullet"
        case .home: return "house.fill"
        case .today: return "calendar.circle.fill"
        case .photos: return "photo.on.rectangle.fill"
        }
    }
}

enum PhotoImportSceneAction: Equatable {
    case startPendingImport
    case pauseCurrentImport
    case wait
}

enum PhotoImportScenePolicy {
    static func action(for phase: ScenePhase, hasPendingImport: Bool) -> PhotoImportSceneAction {
        if phase == .active {
            return hasPendingImport ? .startPendingImport : .wait
        }
        return hasPendingImport ? .wait : .pauseCurrentImport
    }
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
    @State private var showAuxiliaryMenu: Bool = false
    @State private var pendingPhotoImportBatchID: UUID?
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
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    if selectedTab == .todo {
                        WebViewWrapper(webViewModel: todoWebViewModel)
                    } else if selectedTab == .home {
                        WebViewWrapper(webViewModel: mainWebViewModel)
                    } else if selectedTab == .today {
                        WebViewWrapper(webViewModel: dateWebViewModel)
                    } else if selectedTab == .photos {
                        WebViewWrapper(webViewModel: photoWebViewModel)
                    }

                    if selectedTab == .photos && shouldShowPhotoImportStatus {
                        Divider()
                        photoImportStatus
                    }
                }

                if showAuxiliaryMenu {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            closeAuxiliaryMenu()
                        }

                    auxiliaryMenu
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            Divider()
            bottomTabBar
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
                requestPhotoImport(batchID: pending.id)
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
            switch PhotoImportScenePolicy.action(
                for: phase,
                hasPendingImport: pendingPhotoImportBatchID != nil
            ) {
            case .startPendingImport:
                startPendingPhotoImportIfActive()
            case .pauseCurrentImport:
                photoImportCoordinator.pause()
            case .wait:
                break
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    private var bottomTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    select(tab)
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: isSelected ? tab.selectedSymbolName : tab.symbolName)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(height: 20)

                            if tab == .photos && !photoImportCoordinator.pendingBatches.isEmpty {
                                Circle()
                                    .fill(photoImportStatusColor)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 4, y: -1)
                            }
                        }

                        Text(tab.title)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityValue(isSelected ? "選択中" : "")
                .accessibilityHint(isSelected ? "もう一度押すと最初のページに戻ります" : "")
            }

            Divider()
                .frame(height: 32)

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    showAuxiliaryMenu.toggle()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(showAuxiliaryMenu ? .accentColor : .secondary)
                    .frame(width: 48, height: 44)
                    .background {
                        if showAuxiliaryMenu {
                            Circle()
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 36, height: 36)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("その他の操作")
            .accessibilityValue(showAuxiliaryMenu ? "表示中" : "非表示")
            .accessibilityHint(
                showAuxiliaryMenu
                    ? "補助操作を閉じます"
                    : "現在の画面で利用できる補助操作を表示します"
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }

    private var auxiliaryMenu: some View {
        VStack(spacing: 0) {
            auxiliaryMenuButton(title: "設定", symbolName: "gearshape") {
                closeAuxiliaryMenu()
                settingsDidSave = false
                showSettings = true
            }

            if selectedTab == .today {
                Divider()
                    .padding(.horizontal, 16)

                auxiliaryMenuButton(title: "今日に戻る", symbolName: "calendar") {
                    closeAuxiliaryMenu()
                    openTodayPage()
                }

                Divider()
                    .padding(.leading, 52)

                auxiliaryMenuButton(title: "今年のページを開く", symbolName: "calendar.badge.clock") {
                    closeAuxiliaryMenu()
                    openCurrentYearPage()
                }
            } else if selectedTab == .photos {
                Divider()
                    .padding(.horizontal, 16)

                auxiliaryMenuButton(title: photoQueueMenuTitle, symbolName: "tray.full") {
                    closeAuxiliaryMenu()
                    presentPhotoQueue()
                }
                .accessibilityLabel("写真アップロードキュー")
                .accessibilityValue(photoQueueAccessibilityValue)
            }
        }
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func auxiliaryMenuButton(
        title: String,
        symbolName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 22)

                Text(title)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var photoImportStatus: some View {
        Button {
            presentPhotoQueue()
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: photoImportCoordinator.isWorking ? "arrow.up.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(photoImportStatusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(photoImportCoordinator.isWorking ? "写真をアップロード中" : "写真アップロードを確認")
                            .font(.subheadline.weight(.semibold))
                        Text(photoImportStatusDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                }

                if photoImportCoordinator.isWorking {
                    ProgressView(value: photoImportCoordinator.progress)
                        .tint(.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("写真アップロードの状態")
        .accessibilityValue(photoImportStatusDetail)
        .accessibilityHint("写真アップロードキューを開きます")
    }

    private var shouldShowPhotoImportStatus: Bool {
        photoImportCoordinator.isWorking || !photoImportCoordinator.pendingBatches.isEmpty
    }

    private var photoImportStatusDetail: String {
        if !photoImportCoordinator.statusMessage.isEmpty {
            return photoImportCoordinator.statusMessage
        }
        return "未完了 \(photoImportCoordinator.pendingBatches.count)件"
    }

    private var photoQueueAccessibilityValue: String {
        if photoImportCoordinator.pendingBatches.isEmpty {
            return "未完了の項目はありません"
        }
        return "未完了 \(photoImportCoordinator.pendingBatches.count)件"
    }

    private var photoQueueMenuTitle: String {
        guard !photoImportCoordinator.pendingBatches.isEmpty else {
            return "写真アップロード"
        }
        return "写真アップロード（\(photoImportCoordinator.pendingBatches.count)件）"
    }

    private var photoImportStatusColor: Color {
        let needsAttention = photoImportCoordinator.batch?.failedCount ?? 0 > 0
            || photoImportCoordinator.pendingBatches.contains {
                $0.failedCount > 0 || $0.state == .commitUncertain
            }
        return needsAttention ? .orange : .accentColor
    }

    private func select(_ tab: AppTab) {
        closeAuxiliaryMenu()
        if selectedTab == tab {
            reset(tab)
        } else {
            selectedTab = tab
        }
    }

    private func reset(_ tab: AppTab) {
        switch tab {
        case .todo:
            todoWebViewModel.resetToInitialPage()
        case .home:
            mainWebViewModel.resetToInitialPage()
        case .today:
            openTodayPage()
        case .photos:
            photoWebViewModel.resetToInitialPage()
        }
    }

    private func openTodayPage() {
        currentDate = getCurrentDate()
        if let url = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)") {
            dateWebViewModel.loadURL(url)
        }
    }

    private func openCurrentYearPage() {
        let year = Calendar.current.component(.year, from: Date())
        if let url = URL(string: "https://scrapbox.io/\(projectName)/\(year)年") {
            dateWebViewModel.loadURL(url)
        }
    }

    private func presentPhotoQueue() {
        photoImportCoordinator.refreshQueue()
        showPhotoQueue = true
    }

    private func closeAuxiliaryMenu() {
        withAnimation(.easeOut(duration: 0.15)) {
            showAuxiliaryMenu = false
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
            requestPhotoImport(batchID: batchID)
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

    private func requestPhotoImport(batchID: UUID) {
        pendingPhotoImportBatchID = batchID
        startPendingPhotoImportIfActive()
    }

    private func startPendingPhotoImportIfActive() {
        guard PhotoImportScenePolicy.action(
            for: scenePhase,
            hasPendingImport: pendingPhotoImportBatchID != nil
        ) == .startPendingImport,
              let batchID = pendingPhotoImportBatchID else { return }
        pendingPhotoImportBatchID = nil
        beginPhotoImport(batchID: batchID)
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
                Text("\(batch.processedCount) / \(batch.items.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if batch.skippedCount > 0 {
                    Text("重複スキップ：\(batch.skippedCount)枚")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
            VStack(spacing: 0) {
                if coordinator.isPresented {
                    PhotoImportProgressView(coordinator: coordinator)
                        .padding()
                }

                Group {
                    if coordinator.pendingBatches.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("未完了のアップロードはありません")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(coordinator.pendingBatches) { batch in
                            HStack {
                                Button {
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
                                .disabled(
                                    coordinator.isPresented && coordinator.batch?.id == batch.id
                                        || coordinator.isWorking && coordinator.batch?.id != batch.id
                                )

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
        return "\(batch.processedCount) / \(batch.items.count)枚・\(state)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
