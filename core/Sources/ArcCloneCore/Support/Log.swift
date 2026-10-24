import os

public enum Log {
    static let subsystem = "dev.arcclone.browser"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let scripts = Logger(subsystem: subsystem, category: "scripts")
    public static let web = Logger(subsystem: subsystem, category: "web")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let agent = Logger(subsystem: subsystem, category: "agent")
    public static let extensions = Logger(subsystem: subsystem, category: "extensions")
}
