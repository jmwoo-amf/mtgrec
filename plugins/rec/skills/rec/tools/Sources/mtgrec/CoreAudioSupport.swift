import Foundation
import CoreAudio
import AudioToolbox

/// CoreAudio 프로퍼티 접근을 감싼 얇은 헬퍼. 셀렉터마다 주소 구조체를 만들고
/// 크기를 두 번 물어보는 보일러플레이트가 호출부를 덮지 않게 한다.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         default fallback: T) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cf else { return nil }
        return cf as String
    }

    /// 기본 입력 장치의 (AudioDeviceID, UID, 표시 이름).
    static func defaultInputDevice() -> (id: AudioDeviceID, uid: String, name: String)? {
        guard let id: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultInputDevice,
                                            default: AudioDeviceID(0)),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return (id, uid, string(id, kAudioObjectPropertyName) ?? "unknown input")
    }

    static func defaultOutputDevice() -> (id: AudioDeviceID, uid: String, name: String)? {
        guard let id: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultOutputDevice,
                                            default: AudioDeviceID(0)),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return (id, uid, string(id, kAudioObjectPropertyName) ?? "unknown output")
    }

    /// 장치의 스트림별 채널 수. aggregate device 를 만든 뒤 버퍼 배치를 확인하는 데 쓴다.
    static func inputChannelsPerStream(_ device: AudioObjectID) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration,
                              scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
