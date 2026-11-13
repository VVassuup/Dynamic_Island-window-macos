import Foundation
import CoreAudio
import AudioToolbox

/// Системная громкость через CoreAudio: чтение, запись, mute и слежение за изменениями
/// (клавиши громкости, смена устройства вывода). Колбэки приходят на главном потоке.
final class VolumeService {
    /// (громкость 0…1, mute, доступна ли регулировка у текущего устройства)
    var onChange: ((Double, Bool, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?

    private var defaultDeviceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    deinit { detachDevice() }

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachDefaultDevice() }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, .main, block)
        attachDefaultDevice()
    }

    // MARK: - чтение / запись

    var isAvailable: Bool {
        device != kAudioObjectUnknown && AudioObjectHasProperty(device, &volumeAddr)
    }

    var volume: Double {
        guard isAvailable else { return 0 }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &size, &v)
        return err == noErr ? Double(v) : 0
    }

    var isMuted: Bool {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &muteAddr) else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &m)
        return err == noErr && m != 0
    }

    func setVolume(_ value: Double) {
        guard isAvailable, settable(&volumeAddr) else { return }
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &volumeAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if v > 0 && isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &muteAddr), settable(&muteAddr) else { return }
        var m = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    // MARK: - устройство

    private func settable(_ addr: inout AudioObjectPropertyAddress) -> Bool {
        var ok = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &addr, &ok) == noErr && ok.boolValue
    }

    private func attachDefaultDevice() {
        detachDevice()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, 0, nil, &size, &id)
        device = id

        if device != kAudioObjectUnknown {
            let vb: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
            let mb: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
            if AudioObjectHasProperty(device, &volumeAddr) {
                volumeListener = vb
                AudioObjectAddPropertyListenerBlock(device, &volumeAddr, .main, vb)
            }
            if AudioObjectHasProperty(device, &muteAddr) {
                muteListener = mb
                AudioObjectAddPropertyListenerBlock(device, &muteAddr, .main, mb)
            }
        }
        notify()
    }

    private func detachDevice() {
        guard device != kAudioObjectUnknown else { return }
        if let vb = volumeListener { AudioObjectRemovePropertyListenerBlock(device, &volumeAddr, .main, vb) }
        if let mb = muteListener { AudioObjectRemovePropertyListenerBlock(device, &muteAddr, .main, mb) }
        volumeListener = nil
        muteListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func notify() {
        let v = volume, m = isMuted, a = isAvailable
        if Thread.isMainThread { onChange?(v, m, a) }
        else { DispatchQueue.main.async { [weak self] in self?.onChange?(v, m, a) } }
    }
}
