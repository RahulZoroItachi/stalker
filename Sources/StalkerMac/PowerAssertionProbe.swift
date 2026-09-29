import Foundation
import IOKit.pwr_mgt
import StalkerCore

/// Reads per-process power assertions. Requires no permission — verified.
public struct PowerAssertionProbe: EngagementProbe {
    public init() {}

    public func isEngaged(pid: Int32) -> Bool {
        StalkerCore.isEngaged(assertionsByPid: snapshot(), pid: pid)
    }

    func snapshot() -> [Int32: [AssertionRecord]] {
        var out: [Int32: [AssertionRecord]] = [:]
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return out
        }
        for (pidNum, list) in dict {
            let pid = pidNum.int32Value
            var records: [AssertionRecord] = []
            for entry in list {
                let type = entry["AssertType"] as? String ?? ""
                let name = entry["AssertName"] as? String ?? ""
                guard !type.isEmpty else { continue }
                records.append(AssertionRecord(type: type, name: name))
            }
            if !records.isEmpty { out[pid] = records }
        }
        return out
    }
}
