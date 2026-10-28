import AVFoundation
import CoreAudio
import Foundation

public struct AudioInputDevice: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
}

enum AudioDevices {
    static func capture() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    static func isBuiltIn(_ d: AVCaptureDevice) -> Bool {
        d.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
    }

    static func list() -> [AudioInputDevice] {
        capture().map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName, isBuiltIn: isBuiltIn($0)) }
    }

    /// The Mac's own microphone by default, so a connected iPhone or AirPods never silently
    /// becomes the source.
    static func resolve(_ wanted: AudioInputDevice?) -> AVCaptureDevice? {
        let all = capture()
        if let wanted, let d = all.first(where: { $0.uniqueID == wanted.id }) { return d }
        return all.first(where: isBuiltIn) ?? AVCaptureDevice.default(for: .audio) ?? all.first
    }
}

/// Captures the microphone with AVCaptureSession and hands every buffer to the pipeline.
/// Session control (start, stop, reconfigure) runs on `control`; buffers arrive on the pipeline queue.
final class MicrophoneSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let dataOutput = AVCaptureAudioDataOutput()
    let control = DispatchQueue(label: "lectern.recorder.session")
    let pipeline: AudioPipeline
    let requested: AVCaptureDevice
    var device: AVCaptureDevice
    var deviceInput: AVCaptureDeviceInput?
    // owned by the pipeline queue (capture callbacks and the recorder's watchdog both run there)
    var lastBuffer = monotonicNow()
    var nextPTS: CMTime?
    var lastRestart = 0.0
    var observers: [NSObjectProtocol] = []

    enum SetupError: Error {
        case output
        case input(String)
    }

    init(pipeline: AudioPipeline, device: AVCaptureDevice) throws {
        self.pipeline = pipeline
        self.requested = device
        self.device = device
        super.init()
        dataOutput.setSampleBufferDelegate(self, queue: pipeline.queue)
        guard session.canAddOutput(dataOutput) else { throw SetupError.output }
        session.addOutput(dataOutput)
        guard attach(device) else { throw SetupError.input(device.localizedName) }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.pipeline.queue.async { self.lastRestart = monotonicNow() }
                self.control.asyncAfter(deadline: .now() + 1) { self.restart() }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] n in
                guard let d = n.object as? AVCaptureDevice else { return }
                self?.control.async { self?.deviceRemoved(d) }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] n in
                guard let d = n.object as? AVCaptureDevice else { return }
                self?.control.async { self?.deviceAdded(d) }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Switches the session to `d`. If the new input cannot be added the working one is kept.
    @discardableResult
    func attach(_ d: AVCaptureDevice) -> Bool {
        guard let newInput = try? AVCaptureDeviceInput(device: d) else { return false }
        session.beginConfiguration()
        let old = deviceInput
        if let old { session.removeInput(old) }
        let ok = session.canAddInput(newInput)
        if ok {
            session.addInput(newInput)
            deviceInput = newInput
            device = d
        } else if let old, session.canAddInput(old) {
            session.addInput(old)
        }
        session.commitConfiguration()
        guard ok else { return false }
        pipeline.queue.async {
            self.pipeline.deviceName = d.localizedName
            self.pipeline.deviceID = d.uniqueID
            self.pipeline.noteDeviceChange(d.localizedName)
        }
        return true
    }

    func start() { control.async { self.session.startRunning() } }

    /// On `control`.
    func restart() {
        if session.isRunning { session.stopRunning() }
        session.startRunning()
    }

    func deviceRemoved(_ d: AVCaptureDevice) {
        guard d.uniqueID == device.uniqueID else { return }
        let others = AudioDevices.capture().filter { $0.uniqueID != d.uniqueID }
        if let fallback = others.first(where: AudioDevices.isBuiltIn) ?? others.first, attach(fallback),
           !session.isRunning {
            session.startRunning()
        }
    }

    func deviceAdded(_ d: AVCaptureDevice) {
        guard d.uniqueID == requested.uniqueID, d.uniqueID != device.uniqueID else { return }
        if attach(d), !session.isRunning { session.startRunning() }
    }

    func stop(then: @escaping () -> Void) {
        control.async {
            self.session.stopRunning()
            then()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = monotonicNow()
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        let format = AVAudioFormat(cmAudioFormatDescription: fd)
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        pcm.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        // When the sample was taken: the buffer clock stops during sleep, so the age of the buffer on
        // that clock is carried over to the monotonic clock. Implausible ages fall back to its length.
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        var age = CMTimeSubtract(CMClockGetTime(clock), pts).seconds
        if !age.isFinite || age < 0 || age > 5 { age = Double(n) / format.sampleRate }
        lastBuffer = now
        // each buffer should start where the previous one ended: a forward jump is a dropped stretch
        var skipped = 0.0
        if let expected = nextPTS {
            let jump = CMTimeSubtract(pts, expected).seconds
            if jump > 0.002 {
                skipped = jump
            } else if jump < -0.002 {
                pipeline.backwardJumps += 1
            }
        }
        nextPTS = CMTimeAdd(pts, CMTime(value: CMTimeValue(n), timescale: CMTimeScale(format.sampleRate)))
        pipeline.append(pcm, start: now - age, discontinuity: skipped)
    }
}
