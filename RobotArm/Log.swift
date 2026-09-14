import Foundation

/// A plain text log in the app's Documents folder (`robotarm.log`), one line per event, so what
/// the rig did can be read afterwards from the Files app or pulled off the iPad with a cable.
///
/// The status strip shows one line at a time and the moment passes; the wires question in
/// particular ("did the rail signal, and when?") is answered in a fraction of a second and needs
/// to be written down where it can be read later.
enum Log {
    private static let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("robotarm.log")
    private static let queue = DispatchQueue(label: "robotarm.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date()))  \(line)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
