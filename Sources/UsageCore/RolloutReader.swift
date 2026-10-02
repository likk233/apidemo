import Foundation

public actor RolloutReader {
    private struct Cached {
        let date: Date
        let size: UInt64
        let snapshot: CodexSnapshot?
    }
    private var cache: [String: Cached] = [:]
    public init() {}

    public func latest(home: URL, now: Date = Date()) -> CodexSnapshot? {
        let fm = FileManager.default
        var candidates: [(URL, Date, UInt64)] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // UTC matches Codex's session directory layout. Never recurse through all history.
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let path = String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
            let entries = (try? fm.contentsOfDirectory(at: home.appendingPathComponent(path), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for url in entries where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, let size = values.fileSize else { continue }
                candidates.append((url, modified, UInt64(max(0, size))))
            }
        }
        candidates.sort { $0.1 > $1.1 }
        candidates = Array(candidates.prefix(64))
        let active = Set(candidates.map { $0.0.path })
        cache = cache.filter { active.contains($0.key) }
        var latest: CodexSnapshot?
        var budget = 64 * 1_048_576
        for (url, date, size) in candidates {
            let snapshot: CodexSnapshot?
            if let previous = cache[url.path], previous.date == date, previous.size == size {
                snapshot = previous.snapshot
            } else {
                guard budget > 0 else { break }
                let result = Self.lastEvent(url: url, date: date, size: size, byteLimit: min(budget, 8 * 1_048_576))
                budget -= result.bytes
                snapshot = result.snapshot
                cache[url.path] = Cached(date: date, size: size, snapshot: snapshot)
            }
            if let snapshot, latest == nil || snapshot.capturedAt > latest!.capturedAt { latest = snapshot }
        }
        return latest
    }

    // Reverse chunk scan finds the newest event without loading a huge conversation.
    // Lines >1 MiB and files whose event is >8 MiB from the tail are skipped.
    static func lastEvent(url: URL, date: Date, size: UInt64, byteLimit: Int) -> (snapshot: CodexSnapshot?, bytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, 0) }
        defer { try? handle.close() }
        var position = size
        var suffix = Data()
        var droppingLongLine = false
        var bytes = 0
        do {
            while position > 0 && bytes < byteLimit {
                let count = min(Int(min(position, 65_536)), byteLimit - bytes)
                position -= UInt64(count)
                try handle.seek(toOffset: position)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                bytes += chunk.count
                var end = chunk.count
                for index in chunk.indices.reversed() where chunk[index] == 10 {
                    if !droppingLongLine {
                        let tail = chunk.subdata(in: (index + 1)..<end)
                        if tail.count + suffix.count <= 1_048_576 {
                            var line = tail; line.append(suffix)
                            if let snapshot = CodexParser.rollout(line: line, fileDate: date, origin: url.path) { return (snapshot, bytes) }
                        }
                    }
                    suffix = Data()
                    droppingLongLine = false
                    end = index
                }
                if !droppingLongLine {
                    if end + suffix.count > 1_048_576 { suffix = Data(); droppingLongLine = true }
                    else { var next = chunk.subdata(in: 0..<end); next.append(suffix); suffix = next }
                }
            }
            if position == 0 && !droppingLongLine, let snapshot = CodexParser.rollout(line: suffix, fileDate: date, origin: url.path) {
                return (snapshot, bytes)
            }
        } catch { return (nil, bytes) }
        return (nil, bytes)
    }
}
