// Sources/Model/NLParser.swift — on-device NL parsing: ParsedTask, NLParser, HeuristicNLParser
import Foundation

/// The result of parsing a voice transcript into a candidate task. Mirrors the shape of
/// `SAMPLE_TRANSCRIPT_PARSED[].parsed` in `design/tokens.jsx`. `when` is a display string (not a
/// `Date`) because the prototype only ever needs to show "Tomorrow · 2:00 PM"-style text at this
/// stage; resolving an exact `Date` deadline from free text is left to a smarter parser behind
/// this same protocol (see backlog.md).
struct ParsedTask: Sendable, Equatable {
    var title: String
    var details: String
    var when: String
    var priority: Priority
    var durationMinutes: Int?
    var context: String?
}

/// Abstraction over "turn a transcript into a `ParsedTask`" so a smarter (on-device ML or
/// server-assisted) parser can be swapped in later without touching call sites.
protocol NLParser {
    func parse(_ transcript: String) -> ParsedTask
}

/// On-device heuristic parser: `NSDataDetector` for dates/times, keyword scan for
/// priority/duration. No network calls anywhere (constitution I).
struct HeuristicNLParser: NLParser {
    func parse(_ transcript: String) -> ParsedTask {
        ParsedTask(
            title: Self.cleanTitle(from: transcript),
            details: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            when: Self.detectWhen(in: transcript),
            priority: Self.detectPriority(in: transcript),
            durationMinutes: Self.detectDurationMinutes(in: transcript),
            context: nil
        )
    }

    // MARK: - Priority

    private static func detectPriority(in text: String) -> Priority {
        let lower = text.lowercased()
        let highKeywords = ["urgent", "high priority", "important", "asap", "critical"]
        let lowKeywords = ["low priority", "whenever", "no rush", "not urgent"]
        if highKeywords.contains(where: lower.contains) { return .high }
        if lowKeywords.contains(where: lower.contains) { return .low }
        return .medium
    }

    // MARK: - Duration ("45 min", "45 minutes", "1 hr", "2 hours")

    private static func detectDurationMinutes(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+)\s*(minutes?|mins?|hours?|hrs?)"#,
            options: .caseInsensitive
        ) else { return nil }

        let fullRange = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: fullRange),
            let valueRange = Range(match.range(at: 1), in: text),
            let unitRange = Range(match.range(at: 2), in: text),
            let value = Int(text[valueRange])
        else { return nil }

        let unit = text[unitRange].lowercased()
        return unit.hasPrefix("h") ? value * 60 : value
    }

    // MARK: - When (date/time via NSDataDetector, falls back to keyword "tomorrow"/"today")

    private static func detectWhen(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return "Today"
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: fullRange)

        guard let date = matches.first?.date else {
            return text.lowercased().contains("tomorrow") ? "Tomorrow" : "Today"
        }

        let calendar = Calendar.current
        let dayLabel: String
        if calendar.isDateInToday(date) {
            dayLabel = "Today"
        } else if calendar.isDateInTomorrow(date) {
            dayLabel = "Tomorrow"
        } else {
            dayLabel = date.formatted(.dateTime.month().day())
        }
        let timeLabel = date.formatted(.dateTime.hour().minute())
        return "\(dayLabel) · \(timeLabel)"
    }

    // MARK: - Title cleanup (strip lead-in phrases + trailing priority/duration clauses)

    private static func cleanTitle(from text: String) -> String {
        var title = text
        let leadIns = ["remind me to ", "remember to ", "i need to ", "please remember to ", "please "]
        let lower = title.lowercased()
        for leadIn in leadIns where lower.hasPrefix(leadIn) {
            title = String(title.dropFirst(leadIn.count))
            break
        }
        // Sample transcripts trail off with ", high priority" / ", medium priority" style
        // clauses after the substantive title — drop that tail if present.
        if let commaIndex = title.firstIndex(of: ",") {
            let tail = title[title.index(after: commaIndex)...].lowercased()
            if tail.contains("priority") || tail.contains("urgent") {
                title = String(title[..<commaIndex])
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
