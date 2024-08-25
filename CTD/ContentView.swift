import SwiftUI
import WebKit

struct ContentView: View {
    @State private var projectName: String = UserDefaults.standard.string(forKey: "ProjectName") ?? ""
    @State private var showSettings: Bool = false
    
    var body: some View {
        ZStack {
            TabView {
                WebView(url: URL(string: "https://scrapbox.io/\(projectName)")!)
                    .tabItem {
                        Text("メイン")
                    }
                WebView(url: URL(string: "https://scrapbox.io/\(projectName)/ToDo")!)
                    .tabItem {
                        Text("ToDo")
                    }
                WebView(url: URL(string: "https://scrapbox.io/\(projectName)/\(getCurrentDate())")!)
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
}

struct WebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        
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
