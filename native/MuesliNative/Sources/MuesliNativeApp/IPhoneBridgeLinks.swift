import Foundation

enum IPhoneBridgeLinks {
    static let iOSSyncDeepLinkURL = URL(string: "muesli://sync?source=mac_bridge")!
    /// Deliberately still upstream: the iCloud bridge pairs with upstream's iOS
    /// companion app, which this fork does not rebuild. Repoint only if a fork
    /// of muesli-ios ships.
    static let installURL = URL(string: "https://github.com/Muesli-HQ/muesli-ios")!
}
