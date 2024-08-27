import SwiftUI
import WebKit

class WebViewModel: ObservableObject {
    @Published var webView: CustomWebView?
    
    func goBack() {
        webView?.goBack()
    }
    
    func reload() {
        webView?.reload()
    }
}

struct ContentView: View {
    @State private var projectName: String = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
    @State private var showSettings: Bool = false
    @State private var selectedTab = 1 // 初期タブを真ん中に設定
    
    @StateObject private var mainWebViewModel = WebViewModel()
    @StateObject private var todoWebViewModel = WebViewModel()
    @StateObject private var dateWebViewModel = WebViewModel()
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)/ToDo")!, webViewModel: todoWebViewModel)
                    .tabItem {
                        Text("ToDo")
                    }
                    .tag(0)
                    .ignoresSafeArea(edges: .bottom)
                
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)")!, webViewModel: mainWebViewModel)
                    .tabItem {
                        Text("メイン")
                    }
                    .tag(1)
                    .ignoresSafeArea(edges: .bottom)
                
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)/\(getCurrentDate())")!, webViewModel: dateWebViewModel)
                    .tabItem {
                        Text("日付")
                    }
                    .tag(2)
                    .ignoresSafeArea(edges: .bottom)
            }
            .tabViewStyle(PageTabViewStyle())
            .ignoresSafeArea(edges: .bottom)
            
            VStack {
                Spacer()
                
                HStack {
                    Button(action: {
                        switch selectedTab {
                        case 0:
                            todoWebViewModel.goBack()
                        case 1:
                            mainWebViewModel.goBack()
                        case 2:
                            dateWebViewModel.goBack()
                        default:
                            break
                        }
                    }) {
                        Image(systemName: "arrow.backward")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .padding(10)
                            .background(Circle().fill(Color.white.opacity(0.8)))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        switch selectedTab {
                        case 0:
                            todoWebViewModel.reload()
                        case 1:
                            mainWebViewModel.reload()
                        case 2:
                            dateWebViewModel.reload()
                        default:
                            break
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .padding(10)
                            .background(Circle().fill(Color.white.opacity(0.8)))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gearshape")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .padding(10)
                            .background(Circle().fill(Color.white.opacity(0.8)))
                    }
                }
                .padding([.leading, .trailing], 20)
                .padding(.bottom, -15)
                .background(Color.clear)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(projectName: $projectName)
        }
        .onAppear {
            projectName = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
            selectedTab = 1 // アプリ起動時に真ん中のビューを表示
        }
    }
    
    func getCurrentDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: Date())
    }
    
    func getCurrentDateForInput() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M月d日"
        return "#\(dateFormatter.string(from: Date()))"
    }
}

class CustomWebView: WKWebView {
    override var inputAccessoryView: UIView? {
        let accessoryView = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        accessoryView.backgroundColor = UIColor.systemGray5
        
        let button = UIButton(type: .system)
        button.setTitle("今日の日付を挿入", for: .normal)
        button.frame = CGRect(x: 10, y: 5, width: 150, height: 34)
        button.addTarget(self, action: #selector(insertDate), for: .touchUpInside)
        
        accessoryView.addSubview(button)
        
        return accessoryView
    }
    
    @objc func insertDate() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M月d日"
        let dateString = "#\(dateFormatter.string(from: Date()))"
        
        let script = "document.execCommand('insertText', false, '\(dateString)');"
        self.evaluateJavaScript(script, completionHandler: nil)
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let url: URL
    @ObservedObject var webViewModel: WebViewModel
    
    func makeUIView(context: Context) -> CustomWebView {
        let webView = CustomWebView()
        
        // カスタムユーザーエージェントを設定
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
        
        webViewModel.webView = webView
        
        let request = URLRequest(url: url)
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ webView: CustomWebView, context: Context) {
        // URLが更新された場合に再度ロード
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
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
