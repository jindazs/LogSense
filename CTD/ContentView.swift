import SwiftUI
@preconcurrency import WebKit

struct UserDefaultsKeys {
    static let projectName = "ProjectName"
}

class WebViewModel: ObservableObject {
    @Published var webView: CustomWebView?

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

    @StateObject private var mainWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")")!)
    @StateObject private var todoWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")/ToDo")!)
    @StateObject private var dateWebViewModel = WebViewModel(url: URL(string: "https://scrapbox.io/\(UserDefaults.standard.string(forKey: UserDefaultsKeys.projectName) ?? "")")!)

    var body: some View {
        VStack(spacing: 0) {
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

            HStack {
                Button(action: { selectedTab = 0 }) {
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

                Button(action: { selectedTab = 1 }) {
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

                Button(action: { selectedTab = 2 }) {
                    Image(systemName: "calendar")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .padding()
                        .background(Circle().fill(selectedTab == 2 ? Color.gray.opacity(0.3) : Color.clear))
                }
                .onTapGesture(count: 2) {
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

        let userAgent = "Mozilla/5.0 (iOS; CPU iOS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        self.customUserAgent = userAgent
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, UIApplication.shared.canOpenURL(url), navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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

    func updateUIView(_ webView: CustomWebView, context: Context) {}
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
