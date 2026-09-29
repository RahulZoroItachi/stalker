import Foundation

/// Injectable time, so interval and gap logic can be tested deterministically.
public protocol Clock: Sendable {
    var now: Int { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Int { Int(Date().timeIntervalSince1970) }
}

public final class FakeClock: Clock, @unchecked Sendable {
    private var t: Int
    public init(_ t: Int) { self.t = t }
    public var now: Int { t }
    public func advance(_ seconds: Int) { t += seconds }
}
