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
    
    private var pingTimer: Timer?
    private var globalMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        
        if let button = statusItem.button {
            button.title = "待连接"
        }
        
        setupMenu()
        checkAccessibilityPermissions() // 检查权限
        setupGlobalShortcut()
        connectWebSocket()
    }
    
    // MARK: - 权限检查
    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !isTrusted {
            print("⚠️ 警告: 应用未获得辅助功能权限，全局快捷键将失效。")
            print("请前往: 系统设置 -> 隐私与安全性 -> 辅助功能 -> 添加并勾选本应用。")
        }
    }
    
    // MARK: - 全局快捷键设置 (Control + Option + Shift + B)
    private func setupGlobalShortcut() {
        // 字母 'B' 的 KeyCode 是 11
        let targetKeyCode: UInt16 = 11
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            
            // 匹配组合键：⌃ + ⌥ + ⇧
            let requiredModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
            
            if modifiers == requiredModifiers && event.keyCode == targetKeyCode {
                DispatchQueue.main.async {
                    print("快捷键触发：Control+Option+Shift+B")
                    self?.manualReset()
                }
            }
        }
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        
        // 菜单项显示快捷键提示: ⌃⌥⇧B
        let refreshItem = NSMenuItem(title: "手动重连", action: #selector(manualReset), keyEquivalent: "b")
        refreshItem.keyEquivalentModifierMask = [.control, .option, .shift]
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func manualReset() {
        print("执行重连...")
        updateTitle("🔄...")
        reconnect()
    }

    @objc func quitApp() {
        stopTimers()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSApp.terminate(nil)
    }

    // MARK: - WebSocket 逻辑
    func connectWebSocket() {
        stopTimers()
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        sendSubscribeMessage()
        receiveMessage()
        startPingTimer()
    }
    
    private func sendSubscribeMessage() {
        let subscribeMsg = "{\"op\":\"subscribe\",\"args\":[{\"channel\":\"tickers\",\"instId\":\"BTC-USDT\"}]}"
        webSocketTask?.send(.string(subscribeMsg)) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.parsePrice(text) }
                self.receiveMessage()
            case .failure(_):
                self.updateTitle("❌ 断开")
                self.stopTimers()
            }
        }
    }
    
    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.webSocketTask?.send(.string("ping")) { error in
                if error != nil { self?.updateTitle("❌ 离线") }
            }
        }
    }
    
    private func reconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connectWebSocket()
    }
    
    private func stopTimers() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func parsePrice(_ text: String) {
        if text == "pong" { return }
        guard let data = text.data(using: .utf8) else { return }
        if let response = try? JSONDecoder().decode(OKXResponse.self, from: data),
           let lastPrice = response.data?.first?.last,
           let priceDouble = Double(lastPrice) {
            let displayPrice = String(String(format: "%.0f", priceDouble).prefix(3))
            updateTitle("\(displayPrice)")
        }
    }
    
    private func updateTitle(_ title: String) {
        DispatchQueue.main.async {
            self.statusItem.button?.title = title
        }
    }
}

// MARK: - App 入口
@main
struct BtcTickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }
}
