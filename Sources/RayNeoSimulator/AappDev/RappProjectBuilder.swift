import Foundation

/// Builds an rApp project with its own toolchain (`npm run build`, else `npx --no-install rapp build`) when it is
/// opened and whenever a source file changes. The dev server's watcher then deploys the new `build/*.rpk`.
@MainActor final class RappProjectBuilder {
    let project: URL
    var onLog: ((String, Bool) -> Void)?
    var onState: ((_ building: Bool, _ failed: Bool) -> Void)?

    private var timer: Timer?
    private var process: Process?
    private var builtSignature = ""
    private var dirty = false

    init(project: URL) { self.project = project }

    func start() {
        builtSignature = ""
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        process?.terminate(); process = nil
    }

    /// The command line used for this project.
    nonisolated static func command(for project: URL) -> String {
        if let data = try? Data(contentsOf: project.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any], scripts["build"] != nil {
            return "npm run build"
        }
        return "npx --no-install rapp build"
    }

    /// Newest modification time and file count of the sources (everything except build/, node_modules/, dot dirs).
    nonisolated static func signature(of project: URL) -> String {
        let files = FileManager.default
        guard let walker = files.enumerator(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                            options: [.skipsHiddenFiles]) else { return "" }
        var newest: Double = 0, count = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == "build" || name == "node_modules" || name == "dist" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants(); continue }
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]), values.isDirectory != true else { continue }
            count += 1
            newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if count > 5000 { break }
        }
        return "\(count)|\(newest)"
    }

    private func poll() {
        let signature = Self.signature(of: project)
        guard signature != builtSignature else { return }
        if process != nil { dirty = true; return }
        builtSignature = signature
        build()
    }

    private func build() {
        let command = Self.command(for: project)
        onLog?("构建 \(project.lastPathComponent)：\(command)", false)
        onState?(true, false)
        let task = Process()
        // A login shell finds node / npm the way the developer's terminal does (nvm, Homebrew, …).
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = project
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe; task.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        self?.onLog?("[build] \(line)", line.localizedCaseInsensitiveContains("error"))
                    }
                }
            }
        }
        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.process = nil
                    self.onLog?(status == 0 ? "构建完成" : "构建失败（退出码 \(status)），改好后保存会自动重试", status != 0)
                    self.onState?(false, status != 0)
                    if self.dirty { self.dirty = false; self.poll() }
                }
            }
        }
        do { try task.run(); process = task }
        catch { onLog?("无法运行构建：\(error.localizedDescription)", true); onState?(false, true) }
    }
}
