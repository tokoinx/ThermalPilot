// HIDSensors.swift
// Apple Silicon の温度センサーは SMC ではなく IOHID の「センサーハブ」経由で公開されている。
// macmon / Stats / Hot と同じく、IOKit の非公開 API IOHIDEventSystemClient を使って読む。
//
// 非公開 API なので、ヘッダ無しで dlsym により関数ポインタを取得する。
// Mac App Store 配布は不可 (本アプリは Developer ID / ad-hoc 配布前提)。
// root は不要。

import Foundation

#if canImport(IOKit)
import IOKit

public struct HIDTemperatureReading: Sendable, Equatable {
    public let name: String      // IOHID の "Product" プロパティ (例: "PMU tdie1", "NAND CH0 temp")
    public let celsius: Double
}

public final class HIDSensors {
    // HID usage (AppleVendor ページ)
    private static let kHIDPageAppleVendor: Int32 = 0xff00
    private static let kHIDUsageAppleVendorTemperatureSensor: Int32 = 0x0005
    private static let kIOHIDEventTypeTemperature: Int64 = 15

    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private let create: CreateFn
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let matching: CFDictionary

    /// IOKit から非公開シンボルを解決できなければ nil (将来の macOS で消えた場合に備える)。
    public init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
            let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
            let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
            let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
            let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
            let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        else { return nil }

        self.create = create
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        let matchingDict: [String: Any] = [
            "PrimaryUsagePage": Int(Self.kHIDPageAppleVendor),
            "PrimaryUsage": Int(Self.kHIDUsageAppleVendorTemperatureSensor),
        ]
        self.matching = matchingDict as CFDictionary
    }

    /// 現在の全温度センサーを読む。値が 0 以下や 150℃ 超はノイズとして捨てる (macmon と同じ基準)。
    public func readAll() -> [HIDTemperatureReading] {
        guard let client = create(kCFAllocatorDefault) else { return [] }
        defer { Unmanaged<AnyObject>.fromOpaque(client).release() }

        setMatching(client, matching)
        guard let servicesPtr = copyServices(client) else { return [] }
        let services = (Unmanaged<CFArray>.fromOpaque(servicesPtr).takeRetainedValue() as NSArray) as [AnyObject]

        var readings: [HIDTemperatureReading] = []
        readings.reserveCapacity(services.count)

        for service in services {
            let servicePtr = Unmanaged.passUnretained(service).toOpaque()

            var name = "Unknown"
            if let namePtr = copyProperty(servicePtr, "Product" as CFString) {
                name = Unmanaged<CFString>.fromOpaque(namePtr).takeRetainedValue() as String
            }

            guard let eventPtr = copyEvent(servicePtr, Self.kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let event = Unmanaged<AnyObject>.fromOpaque(eventPtr)
            let field = Int32(Self.kIOHIDEventTypeTemperature << 16)
            let value = getFloat(eventPtr, field)
            event.release()

            guard value > 0, value <= 150 else { continue }
            readings.append(HIDTemperatureReading(name: name, celsius: value))
        }
        return readings.sorted { $0.name < $1.name }
    }
}
#endif
