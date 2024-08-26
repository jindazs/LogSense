import SwiftUI
import WebKit

struct ContentView: View {
    @State private var projectName: String = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
    @State private var showSettings: Bool = false
    
    var body: some View {
        ZStack {
            TabView {
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)")!)
                    .tabItem {
                        Text("メイン")
                    }
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)/ToDo")!)
                    .tabItem {
                        Text("ToDo")
                    }
                WebViewWrapper(url: URL(string: "https://scrapbox.io/\(projectName)/\(getCurrentDate())")!)
                    .tabItem {
                        Text("日付")
                    }
            }
            .tabViewStyle(PageTabViewStyle())
            
            VStack {
                Spacer()
                
                HStack {
                    Button(action: {
                        // 戻るボタンのアクション
                    }) {
                        Image(systemName: "arrow.backward")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .padding(10)
                            .background(Circle().fill(Color.gray.opacity(0.5)))
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
                            .background(Circle().fill(Color.gray.opacity(0.5)))
                    }
                }
                .padding([.leading, .trailing, .bottom], 20)
                .background(Color.clear)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(projectName: $projectName)
        }
        .onAppear {
            projectName = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
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
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = CustomWebView()
        
        // カスタムユーザーエージェントを設定
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
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
