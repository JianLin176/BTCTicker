import SwiftUI
import AppKit
import Combine

// MARK: - WebSocket 数据模型
struct OKXResponse: Codable {
    let data: [TickerData]?
    let event: String? // 用于识别 pong 等事件
}
struct TickerData: Codable {
    let last: String
}

// MARK: - 状态栏控制器
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var webSocketTask: URLSessionWebSocketTask?
    private let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    
    // 自动重连与心跳管理
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var isIntentionallyDisconnected = false

    override init() {
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
        menu.autoenablesItems = false
        
        let refreshItem = NSMenuItem(title: "手动重连", action: #selector(manualReset), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func manualReset() {
        print("手动触发重连...")
        reconnect()
    }

    @objc func quitApp() {
        stopTimers()
        isIntentionallyDisconnected = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        NSApp.terminate(nil)
    }

    // MARK: - WebSocket 核心逻辑
    func connectWebSocket() {
        // 重置状态
        stopTimers()
        isIntentionallyDisconnected = false
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        // 1. 发送订阅
        sendSubscribeMessage()
        // 2. 开始接收消息
        receiveMessage()
        // 3. 启动心跳 (每20秒发送一次 ping)
        startPingTimer()
    }
    
    private func sendSubscribeMessage() {
        let subscribeMsg = """
        {
            "op": "subscribe",
            "args": [{"channel": "tickers", "instId": "BTC-USDT"}]
        }
        """
        let message = URLSessionWebSocketTask.Message.string(subscribeMsg)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("订阅发送失败: \(error)")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.parsePrice(text)
                }
                // 成功后继续监听
                self.receiveMessage()
                
            case .failure(let error):
                print("WebSocket 连接丢失: \(error.localizedDescription)")
                if !self.isIntentionallyDisconnected {
                    self.updateTitle("重连中...")
                    self.scheduleReconnect()
                }
            }
        }
    }
    
    // MARK: - 心跳与重连机制
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.webSocketTask?.send(.string("ping")) { error in
                if let error = error {
                    print("Ping 失败: \(error)")
                }
            }
        }
    }
    
    private func scheduleReconnect() {
        // 防止重复开启多个重连定时器
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            print("正在尝试自动重连...")
            self?.connectWebSocket()
        }
    }
    
    private func reconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connectWebSocket()
    }
    
    private func stopTimers() {
        pingTimer?.invalidate()
        reconnectTimer?.invalidate()
    }
    
    // MARK: - 数据处理
    private func parsePrice(_ text: String) {
        // 过滤掉 OKX 的 pong 回复
        if text == "pong" { return }
        
        guard let data = text.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(OKXResponse.self, from: data)
            if let lastPrice = response.data?.first?.last, let priceDouble = Double(lastPrice) {
                // 显示完整整数部分，如需显示前三位可改回你的逻辑
                let displayPrice = String(String(format: "%.0f", priceDouble).prefix(3))
                updateTitle(displayPrice)
            }
        } catch {
            // 解析失败通常是收到频道订阅成功的确认消息，忽略即可
        }
    }
    
    private func updateTitle(_ title: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.title = title
            }
        }
    }
}

// MARK: - App 入口
@main
struct BtcTickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }
}