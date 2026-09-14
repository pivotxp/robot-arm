import Foundation

/// Small helpers for the one networking mistake that keeps costing time: the iPad's wired address
/// has to be on the rail's network (192.168.1.x). 192.168.50.1 — the digits transposed — is a
/// different network and reaches nothing.
enum Net {
    static var addresses: [String] { Canon.interfaces() }
    static var hasRigSubnet: Bool { addresses.contains { $0.contains("192.168.1.") } }
    /// On 192.168.50.x (usually a transposed 192.168.1.50) with no address on the rail's network.
    static var wrongSubnet: Bool { !hasRigSubnet && addresses.contains { $0.contains("192.168.50.") } }
}
