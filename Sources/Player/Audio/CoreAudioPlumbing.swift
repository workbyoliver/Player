import AudioToolbox // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
import CoreAudio

// Small typed helpers over the CoreAudio HAL's C property API.

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }

    static var virtualMainVolume: AudioObjectPropertyAddress {
        .init(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }
}

extension AudioObjectID {
    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static var defaultOutputDevice: AudioObjectID {
        system.get(.init(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self) ?? AudioObjectID(kAudioObjectUnknown)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(self, &address)
            && AudioObjectIsPropertySettable(self, &address, &settable) == noErr
            && settable.boolValue
    }

    func get<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, as type: T.Type) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    func getArray<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, of type: T.Type) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    func getString(_ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String // CoreAudio hands over a +1 reference
    }

    @discardableResult
    func set<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, to value: T) -> Bool {
        var address = address
        return withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!) == noErr
        }
    }
}

/// A CoreAudio property listener delivered on the main queue.
struct PropertyListener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @MainActor () -> Void) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() } // registered on the main queue below
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        self.object = object
        self.address = address
        self.block = block
    }

    func remove() {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
