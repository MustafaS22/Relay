import Foundation
import Network

public enum RemoteAddress {
    /// A direct DNS name or IP. Relay always supplies its own TCP port.
    public static func validated(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            return IPv6Address(host) == nil ? nil : host
        }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }
        guard (1...253).contains(host.utf8.count) else { return nil }
        let dns = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = dns.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    public static func routes(service: String?, discovered: NWEndpoint?, addresses: [String?]) -> [NWEndpoint] {
        var result: [NWEndpoint] = []
        if let discovered { result.append(discovered) }
        for host in addresses.compactMap({ $0.flatMap(validated) }) {
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: NWEndpoint.Port(rawValue: RelayProtocol.port)!)
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        if result.isEmpty, let service {
            result.append(.service(name: service, type: RelayProtocol.service, domain: "local.", interface: nil))
        }
        return result
    }
}
