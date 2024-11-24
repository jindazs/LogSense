import SwiftUI
import WebKit

class WebViewModel: ObservableObject {
    @Published var webView: CustomWebView?
    private var initialURL: URL?
    
    init(url: URL) {
        self.webView = CustomWebView()
        self.initialURL = url
        loadInitialPage()
    }
    
    private func loadInitialPage() {
        if let initialURL = initialURL {
            let request = URLRequest(url: initialURL)
            webView?.load(request)
        }
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
        loadInitialPage() // 初期ページを再度読み込む
    }
    
    func loadURL(_ url: URL) {
        let request = URLRequest(url: url)
        webView?.load(request)
    }
}

struct ContentView: View {
    @State private var projectName: String = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
    @State private var showSettings: Bool = false
    @State private var selectedTab = 1 // 初期タブをメインに設定
    @State private var currentDate = "" // 日付を保持するState
    
    @StateObject private var mainWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: "ProjectName") ?? "")")!)
    @StateObject private var todoWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: "ProjectName") ?? "")/ToDo")!)
    @StateObject private var dateWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: "ProjectName") ?? "")")!) // 後で日付を設定
    
    var body: some View {
        VStack(spacing: 0) {
            // 各WebViewを事前に生成してキャッシュする
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
            
            // アイコンを含むボトムバー
            HStack {
                Button(action: {
                    selectedTab = 0
                }) {
                    Image(systemName: "list.bullet")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 0 ? Color.gray.opacity(0.2) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    todoWebViewModel.resetToInitialPage() // ダブルタップで初期ページにリセット
                }
                
                Spacer()
                
                Button(action: {
                    selectedTab = 1
                }) {
                    Image(systemName: "house.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 1 ? Color.gray.opacity(0.2) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    mainWebViewModel.resetToInitialPage() // ダブルタップで初期ページにリセット
                }
                .onTapGesture(count: 3) { // 3回タップでSettingsViewを表示
                    showSettings.toggle()
                }
                
                Spacer()
                
                Button(action: {
                    selectedTab = 2
                }) {
                    Image(systemName: "calendar")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 2 ? Color.gray.opacity(0.2) : Color.clear))
                }
                .onTapGesture(count: 2) {
                    // ダブルタップ時にcurrentDateを再取得し、URLを再構築
                    currentDate = getCurrentDate() // 最新の日付を取得
                    let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
                    dateWebViewModel.loadURL(dateUrl) // 最新の日付URLをロード
                }
            }
            .padding([.leading, .trailing], 40)
            .padding(.bottom, 0) // 指定されたpaddingを0に設定
            .background(Color.white)
        }
        .onAppear {
            projectName = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
            currentDate = getCurrentDate() // アプリ起動時に現在の日付を取得
            let dateUrl = URL(string: "https://scrapbox.io/\(projectName)/\(currentDate)")!
            dateWebViewModel.loadURL(dateUrl) // 日付URLをロード
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
        self.allowsBackForwardNavigationGestures = true // スワイプで進む・戻るを有効にする
        self.navigationDelegate = self // NavigationDelegateを設定
        
        // User Agentの設定
        if UIDevice.current.userInterfaceIdiom == .phone {
            self.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        } else {
            self.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var inputAccessoryView: UIView? {
        let accessoryView = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 30))
        accessoryView.backgroundColor = UIColor.systemGray5
        
        let buttonStack = UIStackView(frame: accessoryView.bounds)
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        
        let dateButton = UIButton(type: .system)
        dateButton.setTitle("Today", for: .normal)
        dateButton.addTarget(self, action: #selector(insertDate), for: .touchUpInside)
        
        let dismissButton = UIButton(type: .system)
        dismissButton.setTitle("Done", for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
        
        buttonStack.addArrangedSubview(dateButton)
        buttonStack.addArrangedSubview(dismissButton)
        
        accessoryView.addSubview(buttonStack)
        
        return accessoryView
    }
    
    @objc func insertDate() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M月d日"
        let dateString = "#\(dateFormatter.string(from: Date()))"
        
        let script = "document.execCommand('insertText', false, '\(dateString)');"
        self.evaluateJavaScript(script, completionHandler: nil)
    }
    
    @objc func dismissKeyboard() {
        let script = "document.activeElement.blur();"
        self.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("Failed to dismiss keyboard: \(error.localizedDescription)")
            }
        }
    }
    
    // 外部リンクをデフォルトブラウザで開く
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            if url.host != nil {
                // 外部ブラウザで開く
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}



struct WebViewWrapper: UIViewRepresentable {
    @ObservedObject var webViewModel: WebViewModel
    
    func makeUIView(context: Context) -> CustomWebView {
        let webView = webViewModel.webView ?? CustomWebView()
        webViewModel.webView = webView
        return webView
    }
    
    func updateUIView(_ webView: CustomWebView, context: Context) {
        // キャッシュされたWebViewをそのまま使用するので、ここでは何もしません
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
                UserDefaults.standard.set(projectName, forKey: "ProjectName")
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// プレビュー用のコードを追加
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
