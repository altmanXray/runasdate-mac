// MacRunAsDate —— 以指定的日期时间运行某个程序（macOS 版，界面仿 NirSoft RunAsDate）
import AppKit
import SwiftUI

// MARK: - 数据模型

enum DateMode: String, CaseIterable, Identifiable {
    case absolute = "绝对日期/时间"
    case relative = "相对当前时间"
    var id: Self { self }
}

enum RelUnit: String, CaseIterable, Identifiable {
    case minutes = "分钟", hours = "小时", days = "天", months = "月", years = "年"
    var id: Self { self }
    var component: Calendar.Component {
        switch self {
        case .minutes: return .minute
        case .hours: return .hour
        case .days: return .day
        case .months: return .month
        case .years: return .year
        }
    }
    /// BSD `date -v` 的单位字母
    var dateFlag: String {
        switch self {
        case .minutes: return "M"
        case .hours: return "H"
        case .days: return "d"
        case .months: return "m"
        case .years: return "y"
        }
    }
}

struct LaunchError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class Model: ObservableObject {
    @Published var appPath = ""
    @Published var mode: DateMode = .absolute
    @Published var date = Date()
    @Published var relAmount = -1
    @Published var relUnit: RelUnit = .days
    @Published var params = ""
    @Published var folder = ""
    @Published var moveForward = true
    @Published var returnAfter = false
    @Published var returnSeconds = 10
    @Published var shortcutName = ""
    @Published var status = ""
    @Published var statusColor: Color = .secondary
    @Published var showAbout = false

    private let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: 选择文件

    func browseApp() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.treatsFilePackagesAsDirectories = false
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url { setApp(u) }
    }

    func setApp(_ u: URL) {
        appPath = u.path
        if shortcutName.isEmpty { shortcutName = u.deletingPathExtension().lastPathComponent + "（伪造时间）" }
    }

    func browseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }

    // MARK: 计算

    func targetDate() -> Date {
        switch mode {
        case .absolute: return date
        case .relative:
            return Calendar.current.date(byAdding: relUnit.component, value: relAmount, to: Date()) ?? Date()
        }
    }

    var isAppBundle: Bool {
        appPath.trimmingCharacters(in: .whitespaces).hasSuffix(".app")
    }

    /// 把 .app 解析为其内部可执行文件
    func resolveExecutable() throws -> URL {
        let path = (appPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw LaunchError("请先选择要运行的程序。") }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw LaunchError("找不到文件：\(path)")
        }
        if isDir.boolValue {
            guard let exe = Bundle(url: url)?.executableURL else {
                throw LaunchError("无法从该应用包中找到可执行文件：\(path)")
            }
            return exe
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LaunchError("该文件不可执行：\(path)")
        }
        return url
    }

    /// 把注入库复制到 ~/Library/Application Support/MacRunAsDate，路径稳定，快捷方式也能用
    func installedDylib() throws -> String {
        var src = Bundle.main.url(forResource: "libfaketime", withExtension: "dylib")
        if src == nil, let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let dev = exeDir.appendingPathComponent("libfaketime.dylib")
            if FileManager.default.fileExists(atPath: dev.path) { src = dev }
        }
        guard let src else { throw LaunchError("找不到 libfaketime.dylib，安装包可能不完整。") }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRunAsDate", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("libfaketime.dylib")
        if !fm.contentsEqual(atPath: src.path, andPath: dst.path) {
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        return dst.path
    }

    func timeEnv(dylib: String, target: Date) -> [String: String] {
        var env = ["DYLD_INSERT_LIBRARIES": dylib,
                   "RAD_TIME": String(format: "%.3f", target.timeIntervalSince1970)]
        if !moveForward { env["RAD_FREEZE"] = "1" }
        if returnAfter && returnSeconds > 0 { env["RAD_RETURN_AFTER"] = String(returnSeconds) }
        return env
    }

    // MARK: 运行

    func run() {
        do {
            let exe = try resolveExecutable()
            let dylib = try installedDylib()
            let target = targetDate()
            let warnings = injectionWarnings(exe)

            let p = Process()
            p.executableURL = exe
            p.arguments = splitArguments(params)
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "RAD_REAL_START")
            for (k, v) in timeEnv(dylib: dylib, target: target) { env[k] = v }
            p.environment = env
            let dir = folder.trimmingCharacters(in: .whitespaces)
            if !dir.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let name = exe.lastPathComponent
            p.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    self?.setStatus("\(name)（PID \(proc.processIdentifier)）已退出，退出码 \(proc.terminationStatus)。",
                                    .secondary)
                }
            }
            try p.run()

            var msg = "已启动 \(name)（PID \(p.processIdentifier)），伪造时间：\(displayFmt.string(from: target))"
            if !warnings.isEmpty {
                msg += "\n⚠️ 注入可能无效：" + warnings.joined(separator: "；")
                setStatus(msg, .orange)
            } else {
                setStatus(msg, .green)
            }
        } catch {
            setStatus(error.localizedDescription, .red)
        }
    }

    // MARK: 桌面快捷方式（.command 脚本）

    func createShortcut() {
        do {
            let exe = try resolveExecutable()
            let dylib = try installedDylib()
            var name = shortcutName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = exe.lastPathComponent + "（伪造时间）" }
            name = name.replacingOccurrences(of: "/", with: "-")

            var s = "#!/bin/zsh\n# 由 MacRunAsDate 生成：以伪造的日期时间运行 \(exe.lastPathComponent)\n"
            s += "export DYLD_INSERT_LIBRARIES=\(shellQuote(dylib))\n"
            switch mode {
            case .absolute:
                s += "export RAD_TIME=\(Int64(date.timeIntervalSince1970))\n"
            case .relative:
                let sign = relAmount < 0 ? "-" : "+"
                s += "export RAD_TIME=$(date -v\(sign)\(abs(relAmount))\(relUnit.dateFlag) +%s)\n"
            }
            if !moveForward { s += "export RAD_FREEZE=1\n" }
            if returnAfter && returnSeconds > 0 { s += "export RAD_RETURN_AFTER=\(returnSeconds)\n" }
            s += "unset RAD_REAL_START\n"
            let dir = folder.trimmingCharacters(in: .whitespaces)
            if !dir.isEmpty { s += "cd \(shellQuote((dir as NSString).expandingTildeInPath)) || exit 1\n" }
            let cmd = ([exe.path] + splitArguments(params)).map(shellQuote).joined(separator: " ")
            if isAppBundle {
                // 图形程序：后台启动，终端窗口可直接关闭
                s += "nohup \(cmd) >/dev/null 2>&1 &\ndisown\n"
            } else {
                s += "exec \(cmd)\n"
            }

            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let file = desktop.appendingPathComponent(name + ".command")
            try s.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            setStatus("已在桌面创建快捷方式：\(file.lastPathComponent)（双击即可运行）", .green)
        } catch {
            setStatus("创建快捷方式失败：\(error.localizedDescription)", .red)
        }
    }

    private func setStatus(_ s: String, _ c: Color) {
        status = s
        statusColor = c
    }
}

// MARK: - 工具函数

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 简单的命令行参数拆分：支持单/双引号与反斜杠转义
func splitArguments(_ s: String) -> [String] {
    var args: [String] = []
    var cur = ""
    var inArg = false
    var quote: Character? = nil
    var escape = false
    for ch in s {
        if escape { cur.append(ch); escape = false; inArg = true; continue }
        if ch == "\\" && quote != "'" { escape = true; inArg = true; continue }
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
            continue
        }
        if ch == "\"" || ch == "'" { quote = ch; inArg = true; continue }
        if ch == " " || ch == "\t" || ch == "\n" {
            if inArg { args.append(cur); cur = ""; inArg = false }
            continue
        }
        cur.append(ch)
        inArg = true
    }
    if inArg { args.append(cur) }
    return args
}

func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 检查目标程序是否会拒绝 DYLD_INSERT_LIBRARIES 注入
func injectionWarnings(_ exe: URL) -> [String] {
    let path = exe.resolvingSymlinksInPath().path
    for pre in ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"] where path.hasPrefix(pre) {
        return ["这是受系统完整性保护（SIP）的系统程序，macOS 会忽略注入"]
    }
    let info = runTool("/usr/bin/codesign", ["-dv", "--verbose=2", path])
    let cdLine = info.split(separator: "\n").first { $0.contains("CodeDirectory") }.map(String.init) ?? ""
    if info.contains("Authority=Software Signing") {
        return ["这是 Apple 签名的系统程序，macOS 会忽略注入"]
    }
    let hardened = cdLine.contains("runtime")
    let libValidation = cdLine.contains("library-validation")
    guard hardened || libValidation else { return [] }
    let ent = runTool("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path])
    var w: [String] = []
    if hardened && !ent.contains("com.apple.security.cs.allow-dyld-environment-variables") {
        w.append("该程序启用了 Hardened Runtime，且未允许 DYLD 环境变量")
    }
    if !ent.contains("com.apple.security.cs.disable-library-validation") {
        w.append("该程序启用了库验证，会拒绝加载未经同一开发者签名的库")
    }
    return w
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var m = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("要运行的程序：")
                    HStack {
                        TextField("拖入 .app 或可执行文件", text: $m.appPath)
                        Button("浏览…") { m.browseApp() }
                    }
                }
                GridRow {
                    Text("日期 / 时间：")
                    Picker("", selection: $m.mode) {
                        ForEach(DateMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack(spacing: 8) {
                        DatePicker("", selection: $m.date, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .disabled(m.mode != .absolute)
                        Spacer().frame(width: 24)
                        TextField("", value: $m.relAmount, format: .number)
                            .frame(width: 60)
                            .disabled(m.mode != .relative)
                        Picker("", selection: $m.relUnit) {
                            ForEach(RelUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .disabled(m.mode != .relative)
                    }
                }
                GridRow {
                    Text("参数：")
                    TextField("传给程序的命令行参数", text: $m.params)
                }
                GridRow {
                    Text("起始目录：")
                    HStack {
                        TextField("可选", text: $m.folder)
                        Button("浏览…") { m.browseFolder() }
                    }
                }
            }

            Toggle("时间按真实时间向前流逝（不勾选则时间冻结）", isOn: $m.moveForward)
            HStack {
                Toggle("在以下秒数后恢复为当前真实时间：", isOn: $m.returnAfter)
                TextField("", value: $m.returnSeconds, format: .number)
                    .frame(width: 70)
                    .disabled(!m.returnAfter)
                Text("秒")
            }

            HStack {
                Button("运行") { m.run() }
                    .keyboardShortcut(.defaultAction)
                Button("创建桌面快捷方式 =>") { m.createShortcut() }
                TextField("快捷方式名称", text: $m.shortcutName)
            }

            if !m.status.isEmpty {
                Text(m.status)
                    .font(.callout)
                    .foregroundColor(m.statusColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("关于") { m.showAbout = true }
                Button("关闭") { NSApp.terminate(nil) }
            }
        }
        .padding(18)
        .frame(width: 620)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            m.setApp(u)
            return true
        }
        .alert("关于 MacRunAsDate", isPresented: $m.showAbout) {
            Button("好") {}
        } message: {
            Text("""
            让某个程序以指定的日期时间运行，系统时钟不受影响。
            原理：通过 DYLD_INSERT_LIBRARIES 注入 libfaketime.dylib，拦截 time、gettimeofday、clock_gettime、NSDate 等时间函数。
            限制：对 Apple 系统程序、开启 Hardened Runtime 或库验证的程序无效；对联网校时的程序无效。
            """)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacRunAsDateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("MacRunAsDate") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
