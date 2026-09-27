import Darwin

/// Freed memory normally stays with the app, in case it's needed again, and
/// Activity Monitor keeps counting it. After a big one-off job (reading a
/// library's tags, decoding a song) it's handed back to macOS instead.
enum Memory {
    static func giveBack() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
