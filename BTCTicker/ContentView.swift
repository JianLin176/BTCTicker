import SwiftUI
import AppKit
import Combine

// MARK: - WebSocket 数据模型
struct OKXResponse: Codable {
    let data: [TickerData]?
    let event: String?
    let arg: SubscribeArg?
}
struct TickerData: Codable {
    let last: String
}
struct SubscribeArg: Codable {
    let instId: String?
}

// MARK: - 币种配置（菜单保留，实际不再用于订阅）
enum Coin: String, CaseIterable {
    case btc = "BTC"
    case mu = "MU"

    var instId: String {
        self == .btc ? "BTC-USDT" : "MU-USDT-SWAP"
    }

    // 菜单栏显示前缀
    var label: String {
        self == .btc ? "B" : "M"
    }
}

// MARK: - 状态栏控制器
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var webSocketTask: URLSessionWebSocketTask?
    private let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!

    private var pingTimer: Timer?
    private var globalMonitor: Any?
    private var currentCoin: Coin // 仅用于菜单展示，不再控制订阅
    private var coinSubMenu: NSMenu?
    
    // 缓存两个币种价格
    private var btcPrice: String?
    private var muPrice: String?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 读取上次选择的币种，读不到默认 BTC（仅菜单使用）
        if let saved = UserDefaults.standard.string(forKey: "selectedCoin"), let coin = Coin(rawValue: saved) {
            currentCoin = coin
        } else {
            currentCoin = .btc
        }
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

        // 切换币种子菜单（保留UI，仅修改勾选状态，不控制行情订阅）
        let switchItem = NSMenuItem(title: "切换币种", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        for coin in Coin.allCases {
            let item = NSMenuItem(title: coin.rawValue, action: #selector(switchCoin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = coin
            item.state = (coin == currentCoin) ? .on : .off
            subMenu.addItem(item)
        }
        coinSubMenu = subMenu
        switchItem.submenu = subMenu
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())

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

    @objc private func switchCoin(_ sender: NSMenuItem) {
        guard let coin = sender.representedObject as? Coin, coin != currentCoin else { return }
        currentCoin = coin
        UserDefaults.standard.set(coin.rawValue, forKey: "selectedCoin")

        // 更新子菜单勾选状态
        if let subMenu = coinSubMenu {
            for item in subMenu.items {
                if let c = item.representedObject as? Coin {
                    item.state = (c == currentCoin) ? .on : .off
                }
            }
        }
        print("【菜单切换】仅更新菜单选中，行情仍然同时拉取 BTC+MU：\(coin.rawValue)")
        // 不再调用 reconnect()，菜单操作不影响行情
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
        // 清空缓存价格
        btcPrice = nil
        muPrice = nil
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        sendSubscribeMessage()
        receiveMessage()
        startPingTimer()
    }
    
    private func sendSubscribeMessage() {
        // 一次性订阅 BTC-USDT + MU-USDT-SWAP
        let subscribeMsg = """
        {
            "op":"subscribe",
            "args":[
                {"channel":"tickers","instId":"BTC-USDT"},
                {"channel":"tickers","instId":"MU-USDT-SWAP"}
            ]
        }
        """
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
        guard let response = try? JSONDecoder().decode(OKXResponse.self, from: data),
              let instId = response.arg?.instId,
              let priceStr = response.data?.first?.last,
              let priceNum = Double(priceStr) else {
            return
        }
        
        let priceDisplay = String(format: "%.0f", priceNum)
        if instId == "BTC-USDT" {
            // BTC 截取前3位
            btcPrice = String(priceDisplay.prefix(4))
        } else if instId == "MU-USDT-SWAP" {
            // MU 截取前4位，不足4位全部展示
            muPrice = String(priceDisplay.prefix(4))
        }
        
        // 两个币种都拿到价格，更新状态栏
        guard let b = btcPrice, let m = muPrice else { return }
        updateTitle("M:\(m) B:\(b)")
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
