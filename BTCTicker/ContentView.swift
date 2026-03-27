import SwiftUI
import AppKit
import Combine

// MARK: - WebSocket 数据模型
struct OKXResponse: Codable {
    let data: [TickerData]?
    let event: String?
}
struct TickerData: Codable {
    let last: String
}

// MARK: - 状态栏控制器
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var webSocketTask: URLSessionWebSocketTask?
    private let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var isIntentionallyDisconnected = false
    private var globalMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        
        if let button = statusItem.button {
            button.title = "₿ 连接中..."
        }
        
        setupMenu()
        setupGlobalShortcut() // 初始化全局快捷键
        connectWebSocket()
    }
    
    // MARK: - 全局快捷键设置
    private func setupGlobalShortcut() {
        // Command + Shift + Control + D
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isTargetModifiers = modifiers.contains([.command, .shift, .control])
            let isDKey = event.keyCode == 2 // kVK_ANSI_D
            if isTargetModifiers && isDKey {
                self.manualReset()
            }
        }
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        
        // 菜单项里也显示快捷键提示
        let refreshItem = NSMenuItem(title: "手动重连", action: #selector(manualReset), keyEquivalent: "d")
        refreshItem.keyEquivalentModifierMask = [.command, .shift, .control]
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func manualReset() {
        print("全局快捷键/菜单：手动触发重连...")
        // 视觉反馈：改变标题让用户知道快捷键生效了
        updateTitle("🔄 重连中")
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
        stopTimers()
        isIntentionallyDisconnected = false
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        sendSubscribeMessage()
        receiveMessage()
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
            if let error = error { print("订阅失败: \(error)") }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.parsePrice(text) }
                self.receiveMessage()
            case .failure(let error):
                print("连接丢失: \(error.localizedDescription)")
                if !self.isIntentionallyDisconnected {
                    self.updateTitle("重连中...")
                    self.scheduleReconnect()
                }
            }
        }
    }
    
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.webSocketTask?.send(.string("ping")) { _ in }
        }
    }
    
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
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
    
    private func parsePrice(_ text: String) {
        if text == "pong" { return }
        guard let data = text.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(OKXResponse.self, from: data)
            if let lastPrice = response.data?.first?.last, let priceDouble = Double(lastPrice) {
                let displayPrice = String(String(format: "%.0f", priceDouble).prefix(3))
                updateTitle(displayPrice)
            }
        } catch {}
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