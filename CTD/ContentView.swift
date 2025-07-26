import SwiftUI
import WebKit

struct UserDefaultsKeys {
    static let projectName = "ProjectName"
    static let gyazoToken = "GyazoToken"
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
    print("[LogSense] App Group container missing; using UserDefaults.standard")
    return .standard
}

let groupDefaults = sharedDefaults()

class WebViewModel: ObservableObject {
    @Published var webView: CustomWebView?
    private var initialURL: URL

    init(url: URL) {
        self.initialURL = url
        // ① 直接 webView を生成する
        self.webView = CustomWebView()
        // ② 初期ページをロード
        loadInitialPage(url)
    }

    private func loadInitialPage(_ url: URL) {
        let request = URLRequest(url: url)
        webView?.load(request)
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
        loadInitialPage(initialURL)
    }

    func updateInitialURL(_ url: URL) {
        initialURL = url
        loadInitialPage(url)
    }

    func loadURL(_ url: URL) {
        let request = URLRequest(url: url)
        webView?.load(request)
    }
}

struct ContentView: View {
    @State private var projectName: String = groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? ""
    @State private var gyazoToken: String = groupDefaults.string(forKey: UserDefaultsKeys.gyazoToken) ?? ""
    @State private var showSettings: Bool = false
    @State private var selectedTab = 1
    @State private var currentDate = ""

    @StateObject private var mainWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )
    @StateObject private var todoWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")/ToDo")!
    )
    @StateObject private var dateWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            if selectedTab == 0 {
                WebViewWrapper(webViewModel: todoWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if selectedTab == 1 {
                WebViewWrapper(webViewModel: mainWebViewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if selectedTab == 2 {
                WebViewWrapper(webViewModel: dateWebViewModel)
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
                        selectedTab = 0
                    }) {
                        Image(systemName: "list.bullet")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == 0 ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        todoWebViewModel.resetToInitialPage()
                    }
                    Spacer()
                    Button(action: {
                        selectedTab = 1
                    }) {
                        Image(systemName: "house.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == 1 ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                    }
                    .onTapGesture(count: 2) {
                        mainWebViewModel.resetToInitialPage()
                    }
                    .onTapGesture(count: 3) {
                        showSettings.toggle()
                    }
                    Spacer()
                    Button(action: {
                        selectedTab = 2
                    }) {
                        Image(systemName: "calendar")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12.5, height: 12.5)
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                            .overlay(
                                Circle().stroke(selectedTab == 2 ? Color.gray.opacity(0.3) : Color.clear, lineWidth: 2)
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
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear {
            projectName = groupDefaults.string(forKey: UserDefaultsKeys.projectName) ?? ""
            currentDate = getCurrentDate()
            let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
            dateWebViewModel.loadURL(dateUrl)
        }
        .sheet(isPresented: $showSettings, onDismiss: applyProjectName) {
            SettingsView(projectName: $projectName, gyazoToken: $gyazoToken)
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

        let dateBaseURL = mainURL
        dateWebViewModel.updateInitialURL(dateBaseURL)
        let dateURL = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
        dateWebViewModel.loadURL(dateURL)
    }

    func getCurrentDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: Date())
    }

    private func handleIncomingURL(_ url: URL) {
        // Expect: logsense://open?scrapboxUrl=&lt;percentEncodedURL&gt;
        print("[LogSense] handleIncomingURL \(url.absoluteString)")
        guard url.scheme == "logsense", url.host == "open" else {
            print("[LogSense] invalid scheme or host")
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scrapParam = components?.queryItems?.first(where: { $0.name == "scrapboxUrl" })?.value
        print("[LogSense] scrapParam=\(scrapParam ?? "nil")")

        guard let encoded = scrapParam,
              let targetURL = URL(string: encoded) else { return }
        print("[LogSense] targetURL = \(targetURL)")

        // Switch to main tab and load the page
        selectedTab = 1
        mainWebViewModel.loadURL(targetURL)
        print("[LogSense] loaded URL in main web view")
    }
}

class CustomWebView: WKWebView, WKNavigationDelegate {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        self.allowsBackForwardNavigationGestures = true
        self.navigationDelegate = self

        let userAgent = "Mozilla/5.0 (iOS; CPU iOS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        self.customUserAgent = userAgent

        // 起動時にCookieをWebViewに読み込む
        loadCookies()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // -----------------------------
    // ここからが「Today」ボタンと「Done」ボタンの実装
    // -----------------------------
    override var inputAccessoryView: UIView? {
        let accessoryView = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 40))
        accessoryView.backgroundColor = UIColor.systemGray5

        let buttonStack = UIStackView(frame: accessoryView.bounds)
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually

        let dateButton = UIButton(type: .system)
        dateButton.setTitle("Today", for: .normal)

        // シングルタップで日付を挿入
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(insertDate))
        singleTap.numberOfTapsRequired = 1

        dateButton.addGestureRecognizer(singleTap)

        let dismissButton = UIButton(type: .system)
        dismissButton.setTitle("Done", for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)

        buttonStack.addArrangedSubview(dateButton)
        buttonStack.addArrangedSubview(dismissButton)
        accessoryView.addSubview(buttonStack)

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
                print("Failed to dismiss keyboard: \(error.localizedDescription)")
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

        // GoogleログインやScrapbox、cosenseなど
        let allowInAppIfHostContains = [
            "scrapbox.io",
            "google",
            "accounts.google",
            "cosense"
        ]

        // ホスト名に特定文字列が含まれたらアプリ内で開く
        if let host = url.host,
           allowInAppIfHostContains.contains(where: { host.contains($0) }) {
            decisionHandler(.allow)
        }
        else if navigationAction.navigationType == .linkActivated,
                UIApplication.shared.canOpenURL(url) {
            // 外部リンクはブラウザで開く
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
        else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // ページ読み込み完了時にCookieを保存
        saveCookies()
    }

    // MARK: - Cookie Persistence

    /// WebViewのCookieをHTTPCookieStorageに保存
    private func saveCookies() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let storage = HTTPCookieStorage.shared
            for cookie in cookies {
                storage.setCookie(cookie)
            }
        }
    }

    /// アプリ起動時などにHTTPCookieStorageに保存してあるCookieをWebViewに反映
    private func loadCookies() {
        let storage = HTTPCookieStorage.shared
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        storage.cookies?.forEach { cookieStore.setCookie($0) }
    }
}

struct WebViewWrapper: UIViewRepresentable {
    @ObservedObject var webViewModel: WebViewModel

    func makeUIView(context: Context) -> CustomWebView {
        if webViewModel.webView == nil {
            webViewModel.webView = CustomWebView()
        }
        return webViewModel.webView!
    }

    func updateUIView(_ uiView: CustomWebView, context: Context) {
        // 既存のWebViewを使うので更新処理は不要
    }
}

struct SettingsView: View {
    @Binding var projectName: String
    @Binding var gyazoToken: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("プロジェクト名")) {
                    TextField("プロジェクト名", text: $projectName)
                }
                Section(header: Text("Gyazo Token")) {
                    SecureField("access token", text: $gyazoToken)
                }
            }
            .navigationBarItems(trailing: Button("保存") {
                groupDefaults.set(projectName, forKey: UserDefaultsKeys.projectName)
                groupDefaults.set(gyazoToken, forKey: UserDefaultsKeys.gyazoToken)
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
