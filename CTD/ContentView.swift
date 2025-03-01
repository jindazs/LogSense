import SwiftUI
@preconcurrency import WebKit

struct UserDefaultsKeys {
    static let projectName = "ProjectName"
}

class WebViewModel: ObservableObject {
    @Published var webView: CustomWebView?

    // WebView生成時に初期URLをロード
    init(url: URL) {
        DispatchQueue.main.async { [weak self] in
            self?.webView = CustomWebView()
            self?.loadInitialPage(url)
        }
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
        webView?.reload()
    }

    func loadURL(_ url: URL) {
        let request = URLRequest(url: url)
        webView?.load(request)
    }
}

struct ContentView: View {
    @State private var projectName: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? ""
    @State private var showSettings: Bool = false
    @State private var selectedTab = 1
    @State private var currentDate = ""

    // タブごとにWebViewModelを用意してキャッシュ
    @StateObject private var mainWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )
    @StateObject private var todoWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")/ToDo")!
    )
    @StateObject private var dateWebViewModel = WebViewModel(
        url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")")!
    )

    var body: some View {
        VStack(spacing: 0) {
            // 選択中のタブに応じて表示するWebViewを切り替え
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

            // ボトムバー
            HStack {
                // ToDoタブ
                Button(action: {
                    selectedTab = 0
                }) {
                    Image(systemName: "list.bullet")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 0 ? Color.gray.opacity(0.3) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    todoWebViewModel.resetToInitialPage()
                }

                Spacer()

                // メインタブ
                Button(action: {
                    selectedTab = 1
                }) {
                    Image(systemName: "house.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 1 ? Color.gray.opacity(0.3) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    mainWebViewModel.resetToInitialPage()
                }
                .onTapGesture(count: 3) {
                    showSettings.toggle()
                }

                Spacer()

                // 日付タブ
                Button(action: {
                    selectedTab = 2
                }) {
                    Image(systemName: "calendar")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 2 ? Color.gray.opacity(0.3) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    // ダブルタップ時に現在の日付URLを再ロード
                    currentDate = getCurrentDate()
                    let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
                    dateWebViewModel.loadURL(dateUrl)
                }
            }
            .padding([.leading, .trailing], 40)
            .padding(.bottom, 0)
            .background(Color.white)
        }
        .onAppear {
            projectName = UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? ""
            currentDate = getCurrentDate()
            let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
            dateWebViewModel.loadURL(dateUrl)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(projectName: $projectName)
        }
    }

    func getCurrentDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: Date())
    }
}

class CustomWebView: WKWebView, WKNavigationDelegate {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        self.allowsBackForwardNavigationGestures = true
        self.navigationDelegate = self

        // UserAgentを統一
        let userAgent = "Mozilla/5.0 (iOS; CPU iOS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        self.customUserAgent = userAgent

        // 起動時にCookieをWebViewに読み込む
        loadCookies()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // WKNavigationDelegate: ページ遷移の可否を決定
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // GoogleログインやScrapbox、その他アプリ内で処理したいドメイン（"cosense"なども追加）
        let allowInAppIfHostContains = [
            "scrapbox.io",
            "google",
            "accounts.google",
            "cosense"
        ]

        // ホスト名で判定して「アプリ内で開きたいドメイン」なら外部ブラウザに飛ばさない
        if let host = url.host,
           allowInAppIfHostContains.contains(where: { host.contains($0) }) {
            // GoogleログインページやScrapboxのURLはアプリ内で許可
            decisionHandler(.allow)
        }
        else if navigationAction.navigationType == .linkActivated,
                UIApplication.shared.canOpenURL(url) {
            // 上記以外の外部リンクは、外部ブラウザ(Safari)で開く
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
        else {
            // 直打ちURLなどはそのまま許可
            decisionHandler(.allow)
        }
    }

    // ページ読み込み完了後にCookieを保存
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        saveCookies()
    }

    // CookieをWKWebsiteDataStoreからHTTPCookieStorageに同期
    private func saveCookies() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let storage = HTTPCookieStorage.shared
            for cookie in cookies {
                storage.setCookie(cookie)
            }
        }
    }

    // 起動時などにHTTPCookieStorageのCookieをWKWebsiteDataStoreに登録
    private func loadCookies() {
        let storage = HTTPCookieStorage.shared
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore

        for cookie in storage.cookies ?? [] {
            cookieStore.setCookie(cookie)
        }
    }
}

struct WebViewWrapper: UIViewRepresentable {
    @ObservedObject var webViewModel: WebViewModel

    func makeUIView(context: Context) -> CustomWebView {
        // まだWebViewが生成されていない場合のみ初期化
        if webViewModel.webView == nil {
            webViewModel.webView = CustomWebView()
        }
        return webViewModel.webView!
    }

    func updateUIView(_ uiView: CustomWebView, context: Context) {
        // 既存のWebViewを再利用するため、ここでは何もしない
    }
}

struct SettingsView: View {
    @Binding var projectName: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("プロジェクト名")) {
                    TextField("プロジェクト名", text: $projectName)
                }
            }
            .navigationBarItems(trailing: Button("保存") {
                UserDefaults.standard.set(projectName, forKey: UserDefaultsKeys.projectName)
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
