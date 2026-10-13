import Foundation

/// Read-only copy access to guest virtual memory. Never convert a guest address to a host pointer.
public protocol RE4GuestMemoryReading {
    func copyBytes(at guestAddress: UInt32, count: Int) throws -> Data
}
