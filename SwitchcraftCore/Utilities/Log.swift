import os

/// Structured logging. Never log characters or typed text — key codes and groups only.
public enum Log {
    public static let subsystem = "com.switchcraft.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let keyboard = Logger(subsystem: subsystem, category: "keyboard")
    public static let sensor = Logger(subsystem: subsystem, category: "sensor")
    public static let impact = Logger(subsystem: subsystem, category: "impact")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let soundpack = Logger(subsystem: subsystem, category: "soundpack")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
