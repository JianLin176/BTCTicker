import SwiftUI
import AppKit
import Combine

// MARK: - WebSocket 数据模型
struct OKXResponse: Codable {
    let data: [TickerData]?
}
struct TickerData: Codable {
    let last: String
}

// MARK: - 状态栏控制器
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var webSocketTask: URLSessionWebSocketTask?
    private let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    
    override init() {
        // 1. 初始化状态栏
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        super.init()
        
        if let button = statusItem.button {
            button.title = "₿ 连接中..."
        }
        
        setupMenu()
        connectWebSocket()
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        // 重要：关闭自动禁用功能，防止断网时菜单变灰
        menu.autoenablesItems = false
        
        let refreshItem = NSMenuItem(title: "刷新/重置连接", action: #selector(resetConnection), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true // 强制开启
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func resetConnection() {
        print("手动重置连接...")
        updateTitle("重连中...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connectWebSocket()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - WebSocket 逻辑
    func connectWebSocket() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        // 发送订阅消息
        let subscribeMsg = """
        {
            "op": "subscribe",
            "args": [{"channel": "tickers", "instId": "BTC-USDT"}]
        }
        """
        let message = URLSessionWebSocketTask.Message.string(subscribeMsg)
        
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("发送订阅失败: \(error)")
                self?.updateTitle("网络错误")
            }
        }
        
        receiveMessage()
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.parsePrice(text)
                default: break
                }
                self?.receiveMessage()
                
            case .failure(let error):
                print("WebSocket 收到错误: \(error)")
                self?.updateTitle("已断开")
                // 注意：这里不自动重连，等待用户手动刷新或你可以加个 Timer
            }
        }
    }
    
    private func parsePrice(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(OKXResponse.self, from: data)
            if let lastPrice = response.data?.first?.last, let priceDouble = Double(lastPrice) {
                let formattedPrice = String(format: "%.0f", priceDouble)
                updateTitle("\(formattedPrice)")
            }
        } catch {
            // 忽略非 Ticker 数据的解析失败
        }
    }
    
    private func updateTitle(_ title: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.title = "\(title)"
            }
        }
    }
}

// MARK: - App 入口
@main
struct BtcTickerApp: App {
    // 使用 NSApplicationDelegateAdaptor 来管理生命周期更稳妥
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // macOS 13+ 隐藏菜单栏 App 的默认窗口
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 在应用启动后创建控制器
        statusBarController = StatusBarController()
    }
}