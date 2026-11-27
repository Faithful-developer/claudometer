import Foundation

/// Tolerant decoder for `GET /api/oauth/usage`.
///
/// The endpoint is undocumented, so decoding works on loose JSON instead of strict `Codable`:
/// unknown fields are ignored and missing ones are skipped. The `limits` array is preferred;
/// the older top-level keys (`five_hour`, `seven_day`, …) are used only when it is absent.
public enum UsageDecoder {
    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.apiChanged
        }
        var windows = decodeLimits(root["limits"])
        if windows.isEmpty {
            windows = decodeLegacy(root)
        }
        guard !windows.isEmpty else { throw AppError.apiChanged }

        return UsageSnapshot(
            windows: sorted(windows),
            breakdown: decodeBreakdown(root["seven_day_breakdown"]),
            fetchedAt: fetchedAt,
            extraUsage: decodeExtraUsage(root)
        )
    }

    // MARK: - Extra usage

    /// Paid usage past the plan limits, from `spend` or else the older `extra_usage`. Every
    /// sample seen so far has it switched off with null amounts, so the enabled shape is
    /// inferred: anything unexpected gives nil and never affects the limits.
    static func decodeExtraUsage(_ root: [String: Any]) -> ExtraUsage? {
        let spend = root["spend"] as? [String: Any]
        if let value = spend.flatMap(decodeSpend) { return value }
        // `spend` saying it's off is final; the older block only stands in when `spend` is
        // missing or unreadable.
        if spend?["enabled"] as? Bool == false { return nil }
        return (root["extra_usage"] as? [String: Any]).flatMap(decodeLegacyExtraUsage)
    }

    /// `spend`: `used: {amount_minor, currency, exponent}`, `limit` (null, the same kind of
    /// object, or a bare number taken as minor units), `percent`, `enabled`.
    static func decodeSpend(_ spend: [String: Any]) -> ExtraUsage? {
        guard spend["enabled"] as? Bool == true,
              let used = spend["used"] as? [String: Any],
              let minor = finite(used["amount_minor"]), minor >= 0 else { return nil }
        let exponent = digits(used["exponent"])
        let currency = (used["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        let limit: Double?
        switch spend["limit"] {
        case let object as [String: Any]:
            limit = finite(object["amount_minor"]).map { $0 / pow(10, Double(digits(object["exponent"], default: exponent))) }
        case let number as NSNumber:
            limit = finite(number).map { $0 / pow(10, Double(exponent)) }
        default:
            limit = nil
        }
        return ExtraUsage(
            used: minor / pow(10, Double(exponent)),
            limit: limit.flatMap { $0 > 0 ? $0 : nil },
            currency: currency,
            decimals: exponent,
            percent: finite(spend["percent"])
        )
    }

    /// `extra_usage`: `used_credits` and `monthly_limit` in minor units of `decimal_places`.
    static func decodeLegacyExtraUsage(_ extra: [String: Any]) -> ExtraUsage? {
        guard extra["is_enabled"] as? Bool == true,
              let credits = finite(extra["used_credits"]), credits >= 0 else { return nil }
        let decimals = digits(extra["decimal_places"])
        let scale = pow(10, Double(decimals))
        let currency = (extra["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        return ExtraUsage(
            used: credits / scale,
            limit: finite(extra["monthly_limit"]).flatMap { $0 > 0 ? $0 / scale : nil },
            currency: currency,
            decimals: decimals,
            percent: finite(extra["utilization"])
        )
    }

    // MARK: - `limits` array

    static func decodeLimits(_ value: Any?) -> [LimitWindow] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let kind = item["kind"] as? String,
                  let percent = number(item["percent"] ?? item["utilization"]) else { return nil }
            let model = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let group = LimitGroup(rawValue: item["group"] as? String ?? "") ?? groupFor(kind: kind)
            return LimitWindow(
                id: model.map { "\(kind):\($0)" } ?? kind,
                group: group,
                title: title(kind: kind, model: model),
                utilization: percent,
                resetsAt: date(item["resets_at"])
            )
        }
    }

    // MARK: - Legacy top-level keys

    static let legacyKeys: [(key: String, id: String, group: LimitGroup, title: String)] = [
        ("five_hour", "session", .session, "Session (5h)"),
        ("seven_day", "weekly_all", .weekly, "Weekly · all models"),
        ("seven_day_opus", "weekly_scoped:Opus", .weekly, "Weekly · Opus"),
        ("seven_day_sonnet", "weekly_scoped:Sonnet", .weekly, "Weekly · Sonnet"),
    ]

    static func decodeLegacy(_ root: [String: Any]) -> [LimitWindow] {
        legacyKeys.compactMap { entry in
            guard let object = root[entry.key] as? [String: Any],
                  let utilization = number(object["utilization"]) else { return nil }
            return LimitWindow(
                id: entry.id,
                group: entry.group,
                title: entry.title,
                utilization: utilization,
                resetsAt: date(object["resets_at"])
            )
        }
    }

    // MARK: - Breakdown

    static func decodeBreakdown(_ value: Any?) -> [BreakdownRow] {
        guard let rows = (value as? [String: Any])?["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let percent = number(row["percent"]) else { return nil }
            return BreakdownRow(key: key, title: row["display_name"] as? String ?? key, percent: percent)
        }
    }

    // MARK: - Helpers

    static func groupFor(kind: String) -> LimitGroup {
        if kind.hasPrefix("session") || kind == "five_hour" { return .session }
        if kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") { return .weekly }
        return .other
    }

    static func title(kind: String, model: String?) -> String {
        switch kind {
        case "session": return "Session (5h)"
        case "weekly_all": return "Weekly · all models"
        case "weekly_scoped": return "Weekly · \(model ?? "model")"
        default:
            let words = kind.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            let base = words.joined(separator: " ")
            return model.map { "\(base) · \($0)" } ?? base
        }
    }

    static func sorted(_ windows: [LimitWindow]) -> [LimitWindow] {
        func rank(_ w: LimitWindow) -> Int {
            switch (w.group, w.id) {
            case (.session, _): return 0
            case (.weekly, "weekly_all"): return 1
            case (.weekly, _): return 2
            default: return 3
            }
        }
        return windows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// `number`, but only a finite value: strings like "inf" or "nan" parse as Doubles.
    static func finite(_ value: Any?) -> Double? {
        number(value).flatMap { $0.isFinite ? $0 : nil }
    }

    /// Fraction digits of an amount, 0...4 (2 when missing or unreadable).
    static func digits(_ value: Any?, default fallback: Int = 2) -> Int {
        guard let value = finite(value) else { return fallback }
        return Int(min(max(value, 0), 4).rounded())
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return parseISO8601(string)
    }

    /// Parses ISO 8601 with or without fractional seconds (any precision).
    public static func parseISO8601(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Split off the fraction ourselves: the system formatter rejects microseconds.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix { $0.isNumber }
        let zone = afterDot.dropFirst(digits.count)
        guard let base = plain.date(from: String(string[..<dot]) + zone) else { return nil }
        let fraction = Double("0." + digits) ?? 0
        return base.addingTimeInterval(fraction)
    }
}
