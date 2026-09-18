import Foundation

public enum ImlaPaths {
    public static func defaultSupportDirectoryURL(appName: String = "Imla") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Imla") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("imla.db")
    }
}

public enum ImlaNotifications {
    public static let dataDidChange = Notification.Name("com.xshaheen.imla.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
