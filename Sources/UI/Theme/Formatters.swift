import Foundation

enum MetricFormat {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Fixed 4-character percentage string (e.g. `"  0%"`, `"  4%"`, `" 42%"`, `"100%"`)
    /// so monospaced-digit status bar items never jitter in width.
    static func menuPercent(_ pct: Double) -> String {
        let safe = pct.isFinite ? min(max(pct, 0.0), 100.0) : 0.0
        let rounded = min(max(Int(safe.rounded()), 0), 100)
        if rounded < 10 {
            return "  \(rounded)%"
        }
        if rounded < 100 {
            return " \(rounded)%"
        }
        return "100%"
    }

    /// Fixed 4-character GHz string from MHz input (e.g. `"0.8G"`, `"4.7G"`).
    static func menuGHz(_ mhz: Double) -> String {
        let safe = mhz.isFinite ? max(mhz, 0.0) : 0.0
        let tenths = min(max(Int((safe / 100.0).rounded()), 0), 99)
        return "\(tenths / 10).\(tenths % 10)G"
    }

    /// Fixed 5-character Watts string (e.g. `" 4.1W"`, `"38.5W"`).
    static func menuWatts(_ w: Double) -> String {
        let mag = w.isFinite ? abs(w) : 0.0
        let tenths = min(max(Int((mag * 10.0).rounded()), 0), 999)
        let whole = tenths / 10
        let frac = tenths % 10
        if whole < 10 {
            return " \(whole).\(frac)W"
        }
        return "\(whole).\(frac)W"
    }

    /// Human-readable binary byte count (base 1024, aligned with macOS memory reporting).
    static func bytes(_ b: UInt64) -> String {
        if b < 1024 {
            return "\(b) B"
        }
        let kb = Double(b) / 1024.0
        if b < 1024 * 1024 {
            if kb < 10.0 {
                return String(format: "%.1f KB", locale: posixLocale, kb)
            }
            if kb < 1000.0 {
                return String(format: "%.0f KB", locale: posixLocale, kb)
            }
            return String(format: "%.1f MB", locale: posixLocale, kb / 1024.0)
        }
        let mb = kb / 1024.0
        if b < 1024 * 1024 * 1024 {
            if mb < 100.0 {
                return String(format: "%.1f MB", locale: posixLocale, mb)
            }
            if mb < 1000.0 {
                return String(format: "%.0f MB", locale: posixLocale, mb)
            }
            return String(format: "%.1f GB", locale: posixLocale, mb / 1024.0)
        }
        let gb = mb / 1024.0
        if b < 1024 * 1024 * 1024 * 1024 {
            if gb < 1000.0 {
                return String(format: "%.1f GB", locale: posixLocale, gb)
            }
            return String(format: "%.2f TB", locale: posixLocale, gb / 1024.0)
        }
        let tb = gb / 1024.0
        return String(format: "%.2f TB", locale: posixLocale, tb)
    }

    /// Human-readable throughput string (`B/s`, `KB/s`, `MB/s`, `GB/s`).
    static func rate(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec) B/s"
        }
        let kb = Double(bytesPerSec) / 1024.0
        if bytesPerSec < 1024 * 1024 {
            if kb < 10.0 {
                return String(format: "%.1f KB/s", locale: posixLocale, kb)
            }
            if kb < 1000.0 {
                return String(format: "%.0f KB/s", locale: posixLocale, kb)
            }
            return String(format: "%.1f MB/s", locale: posixLocale, kb / 1024.0)
        }
        let mb = kb / 1024.0
        if bytesPerSec < 1024 * 1024 * 1024 {
            if mb < 100.0 {
                return String(format: "%.1f MB/s", locale: posixLocale, mb)
            }
            if mb < 1000.0 {
                return String(format: "%.0f MB/s", locale: posixLocale, mb)
            }
            return String(format: "%.2f GB/s", locale: posixLocale, mb / 1024.0)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB/s", locale: posixLocale, gb)
    }

    /// Compact system uptime string (e.g. `"45s"`, `"5m"`, `"2h 14m"`, `"3d 4h 12m"`).
    static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds)
        if total <= 0 {
            return "0m"
        }
        if total < 60 {
            return "\(total)s"
        }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Formats optional Celsius temperature, returning `"—"` when unavailable.
    static func optionalTemp(_ has: Bool, _ c: Double) -> String {
        guard has, c.isFinite else { return "—" }
        return "\(Int(c.rounded()))°C"
    }

    /// Formats optional GPU MHz reading, labeling deep `RC6` idle explicitly without waking GT.
    static func optionalMHz(_ has: Bool, _ mhz: UInt32, isRC6: Bool) -> String {
        guard has else { return "—" }
        if isRC6 {
            return "0 MHz (RC6)"
        }
        return "\(mhz) MHz"
    }
}
