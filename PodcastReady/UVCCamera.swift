import AVFoundation
import Foundation
import IOKit
import IOKit.usb

// UVC camera control over IOKit. This replaces the second app in the workflow —
// PodcastReady measures the frame AND sets the camera that produced it.
//
// Two things here are deliberately different from CameraController (GPL-3.0),
// which this is informed by:
//
//  1. The configuration descriptor is parsed while the device interface is still
//     alive. CameraController releases the interface and then reads the
//     descriptor pointer it owned — a use-after-free. It usually works, which is
//     exactly why it fails intermittently: the parse silently yields unit id -1,
//     every control then reports "not supported", and a profile appears to apply
//     and doesn't.
//  2. Descriptors are read by byte offset rather than cast to packed C structs,
//     so there is no bridging header and no alignment assumptions.

// MARK: - IOKit plug-in UUIDs
//
// These are `#define`d in IOUSBLib.h / IOCFPlugIn.h as CFUUIDGetConstantUUIDWithBytes
// macros, which the Swift importer does not surface. They have to be restated.
// The byte values are the published, fixed UUIDs of the IOKit interfaces.

private let kIOUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault,
    0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
    0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!

private let kIOUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault,
    0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4,
    0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!

private let kIOUSBInterfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault,
    0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4,
    0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!

private let kIOUSBInterfaceInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault,
    0x73, 0xc9, 0x7a, 0xe8, 0x9e, 0xf3, 0x11, 0xD4,
    0xb1, 0xd0, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!

private let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)!

// MARK: - Control identity

/// How a control should be presented. UVC controls are not all continuous:
/// powerline frequency is a four-value enum and exposure mode is a bitmap, and
/// rendering either as a slider lets you select values the camera rejects.
enum UVCControlKind: Equatable {
    case continuous
    case toggle
    case options([(value: Int, label: String)])

    static func == (a: UVCControlKind, b: UVCControlKind) -> Bool {
        switch (a, b) {
        case (.continuous, .continuous), (.toggle, .toggle): return true
        case let (.options(x), .options(y)): return x.map(\.value) == y.map(\.value)
        default: return false
        }
    }
}

enum UVCControlID: String, CaseIterable, Codable {
    // Camera Terminal
    case exposureTime, exposureAuto, focusAbsolute, focusAuto, zoomAbsolute
    case panAbsolute, tiltAbsolute
    // Processing Unit
    case brightness, contrast, saturation, sharpness, gain
    case whiteBalance, whiteBalanceAuto, powerLineFrequency, backlightCompensation

    var label: String {
        switch self {
        case .exposureTime: return "Exposure Time"
        case .exposureAuto: return "Auto Exposure"
        case .focusAbsolute: return "Focus"
        case .focusAuto: return "Auto Focus"
        case .zoomAbsolute: return "Zoom"
        case .panAbsolute: return "Pan"
        case .tiltAbsolute: return "Tilt"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .sharpness: return "Sharpness"
        case .gain: return "Gain"
        case .whiteBalance: return "White Balance (K)"
        case .whiteBalanceAuto: return "Auto White Balance"
        case .powerLineFrequency: return "Powerline Frequency"
        case .backlightCompensation: return "Backlight Compensation"
        }
    }

    var kind: UVCControlKind {
        switch self {
        // Genuine single-bit controls.
        case .focusAuto, .whiteBalanceAuto:
            return .toggle
        // AE Mode is a BITMAP, not a boolean: 1 = manual, 2 = auto,
        // 4 = shutter priority, 8 = aperture priority. Writing 0 is invalid.
        case .exposureAuto:
            return .options([(1, "Manual"), (8, "Auto")])
        case .powerLineFrequency:
            return .options([(0, "Disabled"), (1, "50 Hz"), (2, "60 Hz"), (3, "Auto")])
        case .backlightCompensation:
            return .options([(0, "Off"), (1, "On")])
        default:
            return .continuous
        }
    }

    /// Pan and tilt share one 8-byte control; this says which half.
    fileprivate var panTiltComponent: Int? {
        switch self {
        case .panAbsolute: return 0
        case .tiltAbsolute: return 1
        default: return nil
        }
    }

    /// UVC selector, byte width, and which unit answers for it.
    fileprivate var spec: (selector: Int, size: Int, unit: UVCUnitKind) {
        switch self {
        case .exposureAuto:           return (0x02, 1, .cameraTerminal)   // AE Mode (bitmap)
        case .exposureTime:           return (0x04, 4, .cameraTerminal)
        case .focusAbsolute:          return (0x06, 2, .cameraTerminal)
        case .focusAuto:              return (0x08, 1, .cameraTerminal)
        case .zoomAbsolute:           return (0x0B, 2, .cameraTerminal)
        case .panAbsolute, .tiltAbsolute: return (0x0D, 8, .cameraTerminal)
        case .backlightCompensation:  return (0x01, 2, .processingUnit)
        case .brightness:             return (0x02, 2, .processingUnit)
        case .contrast:               return (0x03, 2, .processingUnit)
        case .gain:                   return (0x04, 2, .processingUnit)
        // 1 byte per the UVC spec. Declaring it as 2 reads a garbage high byte
        // on this hardware (0x1301 instead of 1).
        case .powerLineFrequency:     return (0x05, 1, .processingUnit)
        case .saturation:             return (0x07, 2, .processingUnit)
        case .sharpness:              return (0x08, 2, .processingUnit)
        case .whiteBalance:           return (0x0A, 2, .processingUnit)
        case .whiteBalanceAuto:       return (0x0B, 1, .processingUnit)
        }
    }
}

fileprivate enum UVCUnitKind { case cameraTerminal, processingUnit }

struct UVCControlState: Identifiable {
    let id: UVCControlID
    let isSupported: Bool
    var current: Int
    let minimum: Int
    let maximum: Int
    let defaultValue: Int
}

// MARK: - Camera

final class UVCCamera {
    private let interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>
    private let cameraTerminalID: Int
    private let processingUnitID: Int
    private let interfaceID: Int

    /// Nil when the device is not a UVC camera we can reach, or when the
    /// descriptor does not name both units — never a partly-initialised camera
    /// whose writes quietly go nowhere.
    init?(device: AVCaptureDevice) {
        guard let ids = Self.vendorProduct(from: device.modelID),
              let service = Self.matchService(vendor: ids.vendor, product: ids.product, uniqueID: device.uniqueID)
        else { return nil }
        defer { IOObjectRelease(service) }

        var foundInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>?
        var units: (ct: Int, pu: Int, iface: Int)?

        Self.withPlugin(service: service, type: kIOUSBDeviceUserClientTypeID) { plugin in
            guard let dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>> =
                    Self.queryInterface(plugin, uuid: kIOUSBDeviceInterfaceID) else { return }
            defer { _ = dev.pointee.pointee.Release(dev) }

            // The VideoControl interface is what answers control requests.
            var request = IOUSBFindInterfaceRequest(
                bInterfaceClass: 0x0E, bInterfaceSubClass: 0x01,
                bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
            var iterator: io_iterator_t = 0
            if dev.pointee.pointee.CreateInterfaceIterator(dev, &request, &iterator) == kIOReturnSuccess {
                defer { IOObjectRelease(iterator) }
                var obj = IOIteratorNext(iterator)
                while obj != 0 {
                    Self.withPlugin(service: obj, type: kIOUSBInterfaceUserClientTypeID) { iplug in
                        if foundInterface == nil {
                            foundInterface = Self.queryInterface(iplug, uuid: kIOUSBInterfaceInterfaceID)
                        }
                    }
                    IOObjectRelease(obj)
                    if foundInterface != nil { break }
                    obj = IOIteratorNext(iterator)
                }
            }

            // Parse INSIDE this closure: the descriptor pointer belongs to `dev`,
            // which is released the moment we return.
            var cd: IOUSBConfigurationDescriptorPtr?
            if dev.pointee.pointee.GetConfigurationDescriptorPtr(dev, 0, &cd) == kIOReturnSuccess, let cd {
                units = Self.parseUnits(cd)
            }
        }

        guard let interface = foundInterface, let units, units.ct >= 0, units.pu >= 0 else {
            if let i = foundInterface { _ = i.pointee.pointee.Release(i) }
            return nil
        }
        self.interface = interface
        self.cameraTerminalID = units.ct
        self.processingUnitID = units.pu
        self.interfaceID = units.iface
    }

    deinit { _ = interface.pointee.pointee.Release(interface) }

    // MARK: Reading and writing

    func read(_ id: UVCControlID) -> UVCControlState {
        let s = id.spec
        let unit = s.unit == .cameraTerminal ? cameraTerminalID : processingUnitID
        let supported = requestInt(.getInfo, selector: s.selector, unit: unit, size: 1) ?? 0
        guard supported != 0 else {
            return UVCControlState(id: id, isSupported: false, current: 0, minimum: 0, maximum: 0, defaultValue: 0)
        }

        // Pan and tilt are two signed 32-bit halves of one 8-byte control, so
        // each is read out of the same request rather than getting its own.
        if let component = id.panTiltComponent {
            guard let cur = panTilt(.getCurrent, unit: unit, component: component),
                  let mn = panTilt(.getMinimum, unit: unit, component: component),
                  let mx = panTilt(.getMaximum, unit: unit, component: component),
                  let df = panTilt(.getDefault, unit: unit, component: component) else {
                return UVCControlState(id: id, isSupported: false, current: 0, minimum: 0, maximum: 0, defaultValue: 0)
            }
            return UVCControlState(id: id, isSupported: mn != mx, current: cur,
                                   minimum: mn, maximum: mx, defaultValue: df)
        }

        let cur = requestInt(.getCurrent, selector: s.selector, unit: unit, size: s.size) ?? 0
        let df = requestInt(.getDefault, selector: s.selector, unit: unit, size: s.size) ?? 0

        switch id.kind {
        case .toggle:
            return UVCControlState(id: id, isSupported: true, current: cur, minimum: 0, maximum: 1, defaultValue: df)
        case .options:
            // A bitmap control's min/max are not a usable range; the option list
            // is filtered against them by the caller where they are meaningful.
            let mn = requestInt(.getMinimum, selector: s.selector, unit: unit, size: s.size) ?? 0
            let mx = requestInt(.getMaximum, selector: s.selector, unit: unit, size: s.size) ?? 0
            return UVCControlState(id: id, isSupported: true, current: cur, minimum: mn, maximum: mx, defaultValue: df)
        case .continuous:
            let mn = requestInt(.getMinimum, selector: s.selector, unit: unit, size: s.size) ?? 0
            let mx = requestInt(.getMaximum, selector: s.selector, unit: unit, size: s.size) ?? 0
            return UVCControlState(id: id, isSupported: mn != mx, current: cur,
                                   minimum: mn, maximum: mx, defaultValue: df)
        }
    }

    func readAll() -> [UVCControlState] {
        UVCControlID.allCases.map { read($0) }
    }

    @discardableResult
    func write(_ id: UVCControlID, value: Int) -> Bool {
        let s = id.spec
        let unit = s.unit == .cameraTerminal ? cameraTerminalID : processingUnitID

        // Writing pan alone would zero tilt, because they share one 8-byte
        // payload. Read the pair, replace one half, write the pair back.
        if let component = id.panTiltComponent {
            guard var bytes = requestBytes(.getCurrent, selector: s.selector, unit: unit, size: 8) else { return false }
            let v = Int32(clamping: value)
            var le = UInt32(bitPattern: v)
            for i in 0..<4 { bytes[component * 4 + i] = UInt8(le & 0xFF); le >>= 8 }
            return setBytes(bytes, selector: s.selector, unit: unit)
        }
        return requestInt(.setCurrent, selector: s.selector, unit: unit, size: s.size, value: value) != nil
    }

    private func panTilt(_ type: Req, unit: Int, component: Int) -> Int? {
        guard let bytes = requestBytes(type, selector: 0x0D, unit: unit, size: 8) else { return nil }
        var raw: UInt32 = 0
        for i in stride(from: 3, through: 0, by: -1) { raw = (raw << 8) | UInt32(bytes[component * 4 + i]) }
        return Int(Int32(bitPattern: raw))          // pan and tilt are signed
    }

    // MARK: UVC control request

    private enum Req: UInt8 {
        case setCurrent = 0x01, getCurrent = 0x81, getMinimum = 0x82
        case getMaximum = 0x83, getResolution = 0x84, getInfo = 0x86, getDefault = 0x87
    }

    /// The one place a UVC control request is issued. Everything else converts.
    private func requestBytes(_ type: Req, selector: Int, unit: Int, size: Int,
                              payload: [UInt8]? = nil) -> [UInt8]? {
        guard unit >= 0, size > 0, size <= 8 else { return nil }
        var buffer = payload ?? [UInt8](repeating: 0, count: size)
        if buffer.count != size { buffer = Array(buffer.prefix(size)) }

        let isOut = (type == .setCurrent)
        let bm: UInt8 = (isOut ? 0x00 : 0x80) | 0x20 | 0x01   // dir | class | interface

        var ok = false
        buffer.withUnsafeMutableBufferPointer { buf in
            var req = IOUSBDevRequest(
                bmRequestType: bm,
                bRequest: type.rawValue,
                wValue: UInt16(selector << 8),
                wIndex: UInt16((unit << 8) | interfaceID),
                wLength: UInt16(size),
                pData: buf.baseAddress,
                wLenDone: 0)
            ok = interface.pointee.pointee.ControlRequest(interface, 0, &req) == kIOReturnSuccess
        }
        return ok ? buffer : nil
    }

    private func setBytes(_ bytes: [UInt8], selector: Int, unit: Int) -> Bool {
        requestBytes(.setCurrent, selector: selector, unit: unit, size: bytes.count, payload: bytes) != nil
    }

    private func requestInt(_ type: Req, selector: Int, unit: Int, size: Int, value: Int? = nil) -> Int? {
        var payload: [UInt8]?
        if let value {
            var v = UInt64(bitPattern: Int64(value))
            var out = [UInt8](repeating: 0, count: size)
            for i in 0..<size { out[i] = UInt8(v & 0xFF); v >>= 8 }   // UVC is little-endian
            payload = out
        }
        guard let bytes = requestBytes(type, selector: selector, unit: unit, size: size, payload: payload) else {
            return nil
        }
        if type == .setCurrent { return value }
        var result = 0
        for i in stride(from: size - 1, through: 0, by: -1) { result = (result << 8) | Int(bytes[i]) }
        return result
    }

    // MARK: Descriptor parsing (by byte offset — no packed structs)

    /// Walks the configuration descriptor for the VideoControl interface and
    /// returns the Camera Terminal and Processing Unit ids it declares.
    private static func parseUnits(_ cd: IOUSBConfigurationDescriptorPtr) -> (ct: Int, pu: Int, iface: Int)? {
        let base = UnsafeRawPointer(cd).assumingMemoryBound(to: UInt8.self)
        let total = Int(base[2]) | (Int(base[3]) << 8)          // wTotalLength
        guard total > 0, total < 65536 else { return nil }

        var offset = Int(base[0])                                // skip config header
        var ct = -1, pu = -1, iface = -1
        var inVideoControl = false

        while offset + 2 <= total {
            let length = Int(base[offset])
            let type = base[offset + 1]
            if length == 0 { break }

            if type == 0x04, length >= 9 {                       // INTERFACE
                let cls = base[offset + 5], sub = base[offset + 6]
                inVideoControl = (cls == 0x0E && sub == 0x01)
                if inVideoControl { iface = Int(base[offset + 2]) }
            } else if type == 0x24, inVideoControl, length >= 4 { // CS_INTERFACE
                switch base[offset + 2] {                         // bDescriptorSubType
                case 0x02: if ct < 0 { ct = Int(base[offset + 3]) }   // INPUT_TERMINAL
                case 0x05: if pu < 0 { pu = Int(base[offset + 3]) }   // PROCESSING_UNIT
                default: break
                }
                if ct >= 0 && pu >= 0 { return (ct, pu, iface) }
            }
            offset += length
        }
        return (ct >= 0 && pu >= 0) ? (ct, pu, iface) : nil
    }

    // MARK: IOKit plumbing

    private static func vendorProduct(from modelID: String) -> (vendor: Int, product: Int)? {
        // e.g. "UVC Camera VendorID_5426 ProductID_3592"
        guard let vr = modelID.range(of: "VendorID_"), let pr = modelID.range(of: "ProductID_") else { return nil }
        let v = modelID[vr.upperBound...].prefix { $0.isNumber }
        let p = modelID[pr.upperBound...].prefix { $0.isNumber }
        guard let vendor = Int(v), let product = Int(p) else { return nil }
        return (vendor, product)
    }

    /// A machine can have two identical cameras, so vendor+product is not an
    /// identity. `uniqueID` starts with the hex locationID, which is.
    private static func matchService(vendor: Int, product: Int, uniqueID: String) -> io_service_t? {
        let dict = IOServiceMatching("IOUSBDevice") as NSMutableDictionary
        dict["idVendor"] = vendor
        dict["idProduct"] = product

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var candidate = IOIteratorNext(iterator)
        var fallback: io_service_t = 0
        while candidate != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(candidate, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let p = props?.takeRetainedValue() as NSDictionary?,
               let location = p["locationID"] as? Int,
               uniqueID.hasPrefix("0x" + String(location, radix: 16)) {
                return candidate
            }
            if fallback == 0 { fallback = candidate } else { IOObjectRelease(candidate) }
            candidate = IOIteratorNext(iterator)
        }
        return fallback != 0 ? fallback : nil
    }

    private static func withPlugin(service: io_service_t, type: CFUUID, body: (UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>>) -> Void) {
        var ref: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, type, kIOCFPlugInInterfaceID, &ref, &score) == kIOReturnSuccess,
              let ref else { return }
        defer { _ = ref.pointee?.pointee.Release(ref) }
        ref.withMemoryRebound(to: UnsafeMutablePointer<IOCFPlugInInterface>.self, capacity: 1) { body($0) }
    }

    private static func queryInterface<T>(_ plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>>,
                                          uuid: CFUUID) -> UnsafeMutablePointer<T>? {
        var ref: LPVOID?
        guard plugin.pointee.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(uuid), &ref) == kIOReturnSuccess,
              let out: UnsafeMutablePointer<T> = ref?.assumingMemoryBound(to: T.self) else { return nil }
        return out
    }
}
