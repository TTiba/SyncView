import Foundation

/// Log simples em ~/Library/Logs/SyncView.log (+ stdout).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SyncView.log")
    }()
    private static let queue = DispatchQueue(label: "syncview.log")
    private static var handle: FileHandle? = {
        // Rotaciona se passar de 5 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) { write("INFO", msg) }
    static func error(_ msg: String) { write("ERRO", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(msg)\n"
        queue.async {
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
