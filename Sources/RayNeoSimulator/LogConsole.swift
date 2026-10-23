import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Developer log console (the Xcode debug area): follows the running emulator's boot.log — the original
/// firmware's own syslog/trace lines from each core plus the emulator's messages — and app-side events
/// (Aapp display link, input), with source/level filters and search.
@MainActor final class LogConsole: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case all = "全部", ap = "AP", bth = "BTH", c1 = "M55C1", emulator = "模拟器", aapp = "Aapp", phone = "手机", app = "App"
        var id: String { rawValue }
    }
    enum Level: Int, Comparable { case debug, info, warning, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    struct Line: Identifiable {
        let id: Int
        let time: Date
        let source: Source
        let level: Level
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published var source: Source = .all
    @Published var errorsOnly = false
    @Published var search = ""
    @Published var paused = false
    @Published var visible = UserDefaults.standard.bool(forKey: "consoleVisible") {
        didSet { UserDefaults.standard.set(visible, forKey: "consoleVisible") }
    }

    /// Every firmware/emulator line as it arrives (boot milestones).
    var onLine: ((String) -> Void)?
    private let limit = 50_000
    private var nextID = 0
    private var file: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var timer: Timer?
    private var held: [Line] = []

    /// Starts following a run's boot.log from the beginning.
    func follow(_ url: URL) {
        file = url; offset = 0; partial = Data()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        append(.app, .info, "日志：\(url.path)")
    }

    func stopFollowing() { poll(); timer?.invalidate(); timer = nil }

    func clear() { lines.removeAll(); held.removeAll() }

    /// App-side events (Aapp link, input, lifecycle).
    func append(_ source: Source, _ level: Level, _ text: String) {
        add(Line(id: nextID, time: Date(), source: source, level: level, text: text))
        nextID += 1
    }

    var filtered: [Line] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return lines.filter { line in
            (source == .all || line.source == source)
                && (!errorsOnly || line.level >= .warning)
                && (needle.isEmpty || line.text.localizedCaseInsensitiveContains(needle))
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RayNeo-日志.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stamp = DateFormatter(); stamp.dateFormat = "HH:mm:ss.SSS"
        let text = filtered.map { "\(stamp.string(from: $0.time)) [\($0.source.rawValue)] \($0.text)" }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func togglePaused() {
        paused.toggle()
        if !paused { held.forEach(add); held.removeAll() }
    }

    // MARK: following boot.log

    private func poll() {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { offset = 0; partial = Data() }          // file replaced
        guard size > offset else { return }
        // At most 2 MB per tick so a log burst never stalls the UI.
        let count = min(size - offset, 2_000_000)
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(count)) else { return }
        offset += UInt64(chunk.count)
        partial.append(chunk)
        guard let lastNewline = partial.lastIndex(of: 10) else { return }
        let complete = partial[partial.startIndex...lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        let text = String(decoding: complete, as: UTF8.self)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let (source, level, body) = Self.classify(String(raw))
            onLine?(body)
            let line = Line(id: nextID, time: Date(), source: source, level: level, text: body)
            nextID += 1
            add(line)
        }
    }

    private func add(_ line: Line) {
        if paused { held.append(line); if held.count > limit { held.removeFirst(held.count - limit) }; return }
        lines.append(line)
        if lines.count > limit + 5_000 { lines.removeFirst(lines.count - limit) }
    }

    /// `[AP] …`, `[BTH] …`, `[C1] …`, `[AP:out] …` come from the firmware trace hooks; `[hh:mm:ss.ffff] [LEVEL] …`
    /// from Renode itself.
    static func classify(_ raw: String) -> (Source, Level, String) {
        func level(of text: String) -> Level {
            let upper = text.uppercased()
            if upper.contains("ERROR") || upper.contains("ASSERT") || upper.contains("FAULT") || upper.contains("PANIC") { return .error }
            if upper.contains("WARN") || upper.contains("FAIL") { return .warning }
            return .info
        }
        for (prefix, source) in [("[AP:out] ", Source.ap), ("[AP] ", .ap), ("[BTH] ", .bth), ("[C1] ", .c1)] where raw.hasPrefix(prefix) {
            let body = String(raw.dropFirst(prefix.count))
            return (source, level(of: body), body)
        }
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let rest = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let lvl: Level = rest.hasPrefix("[ERROR]") ? .error : rest.hasPrefix("[WARNING]") ? .warning
                : rest.hasPrefix("[DEBUG]") || rest.hasPrefix("[NOISY]") ? .debug : .info
            return (.emulator, lvl, rest)
        }
        return (.emulator, level(of: raw), raw)
    }
}

struct LogConsoleView: View {
    @ObservedObject var console: LogConsole
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $console.source) {
                    ForEach(LogConsole.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Toggle("仅警告/错误", isOn: $console.errorsOnly).toggleStyle(.checkbox)
                TextField("搜索", text: $console.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button(console.paused ? "继续" : "暂停") { console.togglePaused() }
                Button("清空") { console.clear() }
                Button("导出…") { console.export() }
            }
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            let rows = console.filtered
            ScrollViewReader { proxy in
                List(rows.suffix(5_000)) { line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .id(line.id)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 14)
                .onChange(of: rows.last?.id) { _, last in
                    if follow, !console.paused, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                // Opening the console or changing the filter jumps to the newest line, like Xcode's debug area.
                .onAppear { if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                .onChange(of: console.source) { _, _ in if let last = console.filtered.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                .onChange(of: console.errorsOnly) { _, _ in if let last = console.filtered.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(_ line: LogConsole.Line) -> Color {
        switch line.level {
        case .error: return .red
        case .warning: return .orange
        case .debug: return .secondary
        case .info: return line.source == .emulator ? .secondary : .primary
        }
    }
}
