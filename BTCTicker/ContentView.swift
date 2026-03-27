import SwiftUI
import AppKit

// MARK: - WebSocket 数据模型
struct OKXResponse: Codable {
    let data: [TickerData]?
}
struct TickerData: Codable {
    let last: String
}

// MARK: - 菜单栏控制器
class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var webSocketTask: URLSessionWebSocketTask?
    
    init() {
        statusBar = NSStatusBar.system
        // 创建菜单栏实例
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "BTC: --"
            button.action = #selector(handleMenuAction)
            button.target = self
            // 允许右键菜单
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        setupMenu()
        connectWebSocket()
    }
    
    // 设置点击菜单
    private func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "刷新/重置连接", action: #selector(resetConnection), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc func handleMenuAction() {
        // 这里可以处理单击逻辑，目前已由 setupMenu 接管
    }

    @objc func resetConnection() {
        print("正在重置连接...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connectWebSocket()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - WebSocket 逻辑
    func connectWebSocket() {
        let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
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
        webSocketTask?.send(message) { error in
            if let error = error {
                print("发送失败: \(error)")
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
                // 递归调用以保持监听
                self?.receiveMessage()
                
            case .failure(let error):
                print("连接错误: \(error)")
                DispatchQueue.main.async {
                    self?.statusItem.button?.title = "连接失败"
                }
            }
        }
    }
    
    private func parsePrice(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(OKXResponse.self, from: data)
            if let lastPrice = response.data?.first?.last {
                // 格式化价格，去掉小数
                if let priceDouble = Double(lastPrice) {
                    let formattedPrice = String(format: "%.0f", priceDouble)
                    DispatchQueue.main.async {
                        self.statusItem.button?.title = "₿ \(formattedPrice)"
                    }
                }
            }
        } catch {
            // 忽略非 ticker 数据包的解析错误
        }
    }
}

// MARK: - App 入口
@main
struct BtcTickerApp: App {
    // 保持控制器引用，防止被垃圾回收
    @State private var controller = StatusBarController()
    
    var body: some Scene {
        // 隐藏主窗口
        Settings {
            EmptyView()
        }
    }
}
