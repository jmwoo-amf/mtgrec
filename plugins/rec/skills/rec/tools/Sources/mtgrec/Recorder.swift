import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// IOProc 은 실시간 스레드에서 돈다. 그 안에서 파일을 쓰거나 메모리를 할당하면
/// 드롭아웃이 생기므로, 콜백은 미리 잡아둔 링버퍼에 밀어넣기만 하고
/// 리샘플링과 파일 쓰기는 별도 스레드가 맡는다.
final class RingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var available = 0
    private let lock = NSLock()
    private(set) var droppedFrames = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if available + count > capacity {
            droppedFrames += count
            return
        }
        for i in 0..<count {
            storage[writeIndex] = pointer[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available += count
    }

    func drain(into destination: inout [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = min(available, destination.count)
        for i in 0..<count {
            destination[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        available -= count
        return count
    }

    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }
}

/// 링버퍼 하나를 받아 48kHz mono 를 목표 샘플레이트로 낮춰 WAV 로 흘려쓴다.
final class TrackWriter {
    let name: String
    let speaker: String
    let url: URL
    private let ring: RingBuffer
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    /// AVAudioFile 은 소멸할 때 WAV 헤더의 길이 필드를 확정한다. 데몬이 exit() 로
    /// 끝나면 소멸자가 돌지 않아 헤더가 초기값으로 남고, 그 파일은 길이 0으로 읽힌다.
    /// 그래서 참조를 optional 로 들고 stop() 에서 명시적으로 놓는다.
    private var file: AVAudioFile?
    /// 실시간 전사기가 tail 하는 헤더 없는 사이드카. WAV 는 ExtAudioFile 이 쓰기를
    /// 버퍼링하고 길이 필드를 close 때 확정하므로 다른 프로세스가 따라 읽을 수 없다.
    /// 여기에는 같은 프레임을 little-endian Int16 으로 붙이기만 한다. 녹음이 끝나면 지운다.
    private var sidecar: FileHandle?
    let sidecarURL: URL
    private var scratch: [Float]
    private(set) var framesWritten = 0
    private(set) var peak: Float = 0

    init(name: String, speaker: String, directory: URL,
         sourceRate: Double, targetRate: Double, ring: RingBuffer,
         writeSidecar: Bool) throws {
        self.name = name
        self.speaker = speaker
        self.ring = ring
        self.url = directory.appendingPathComponent("\(name).wav")
        self.sidecarURL = directory.appendingPathComponent("\(name).pcm")

        guard let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw RecorderError.message("오디오 변환기를 만들 수 없습니다 (\(name))")
        }
        self.sourceFormat = source
        self.targetFormat = target
        self.converter = converter

        // 파일은 16-bit PCM 으로 남긴다. 전사에 충분하고 float 대비 절반 크기다.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        self.scratch = [Float](repeating: 0, count: Int(sourceRate))

        // 사이드카는 부가물이다. 열지 못해도 녹음은 그대로 간다.
        if writeSidecar {
            FileManager.default.createFile(atPath: sidecarURL.path, contents: nil)
            self.sidecar = try? FileHandle(forWritingTo: sidecarURL)
        }
    }

    /// 링버퍼에 쌓인 만큼 꺼내 변환하고 파일에 붙인다. 남은 게 없으면 아무 것도 안 한다.
    func flush() throws {
        while true {
            let count = ring.drain(into: &scratch)
            if count == 0 { return }

            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                               frameCapacity: AVAudioFrameCount(count)) else { return }
            input.frameLength = AVAudioFrameCount(count)
            if let channel = input.floatChannelData?[0] {
                for i in 0..<count {
                    channel[i] = scratch[i]
                    peak = max(peak, abs(scratch[i]))
                }
            }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(count) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if status == .error { throw RecorderError.message("리샘플링 실패 (\(name))") }
            if output.frameLength > 0, let file {
                try file.write(from: output)
                framesWritten += Int(output.frameLength)
                appendSidecar(output)
            }
            if count < scratch.count { return }
        }
    }

    /// 방금 파일에 쓴 것과 같은 프레임을 Int16 로 접어 사이드카에 붙인다.
    /// 실패는 삼킨다. 이것 때문에 캡처가 멈추면 본말이 전도된다.
    private func appendSidecar(_ buffer: AVAudioPCMBuffer) {
        guard let sidecar, let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1, min(1, channel[i]))
            pcm[i] = Int16(clamped * 32767)
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try? sidecar.write(contentsOf: data)
    }

    /// 파일 핸들을 놓아 WAV 헤더를 확정한다. 이걸 빠뜨리면 파일 크기는 맞는데
    /// 헤더의 길이가 0에 가깝게 남아 전사기가 빈 파일로 읽는다.
    func close() {
        file = nil
        try? sidecar?.close()
        sidecar = nil
    }

    var seconds: Double { Double(framesWritten) / targetFormat.sampleRate }
}

enum RecorderError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 마이크와 시스템 오디오 탭을 하나의 private aggregate device 로 묶어
/// 한 IOProc 에서 두 트랙을 받는다. 같은 IO 사이클이라 두 트랙의 프레임 수가
/// 정확히 일치하고, 병합할 때 시간 보정이 필요 없다.
final class Recorder {
    private let targetRate: Double
    private let micOnly: Bool
    private let sysOnly: Bool
    private let muteOutput: Bool
    private let writeSidecar: Bool
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var micRing: RingBuffer
    private var sysRing: RingBuffer
    private var micWriter: TrackWriter?
    private var sysWriter: TrackWriter?
    private var sourceRate: Double = 48000
    private var writerThread: Thread?
    private var running = false

    init(targetRate: Double = 16000, micOnly: Bool, sysOnly: Bool = false, muteOutput: Bool = false,
         writeSidecar: Bool = false) {
        self.targetRate = targetRate
        self.micOnly = micOnly
        self.sysOnly = sysOnly && !micOnly
        self.muteOutput = muteOutput
        self.writeSidecar = writeSidecar
        // 60초분을 잡아둔다. 쓰기 스레드가 250ms 마다 비우므로 넉넉하다.
        self.micRing = RingBuffer(capacity: 48000 * 60)
        self.sysRing = RingBuffer(capacity: 48000 * 60)
    }

    func start(directory: URL) throws {
        guard let input = CA.defaultInputDevice() else {
            throw RecorderError.message("기본 입력 장치를 찾을 수 없습니다")
        }
        if let rate: Float64 = CA.value(input.id, kAudioDevicePropertyNominalSampleRate,
                                        scope: kAudioObjectPropertyScopeInput, default: Float64(0)),
           rate > 0 {
            sourceRate = rate
        }

        // 출력 장치는 sub-device 로 넣지 않는다. 넣지 않아도 탭은 동작하고,
        // 넣으면 스피커가 유휴일 때 클럭이 흔들린다.
        let subDevices: [[String: Any]] = [[
            kAudioSubDeviceUIDKey: input.uid,
            kAudioSubDeviceDriftCompensationKey: 0,
        ]]

        var tapList: [[String: Any]] = []
        if !micOnly {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "mtgrec"
            description.uuid = UUID()
            description.isPrivate = true
            // .muted 는 탭으로는 받되 스피커로 내보내지 않는다. 회의실에서 옆 사람 장비로
            // 소리를 들으면서 내 맥은 회의에 붙여만 두고 녹음할 때 쓴다. 스피커가 울지
            // 않으므로 마이크 누화도 함께 사라진다.
            description.muteBehavior = muteOutput ? .muted : .unmuted

            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr else {
                throw RecorderError.message("시스템 오디오 탭 생성 실패 (status \(status)). 마이크만 녹음하려면 --mic-only 를 쓰십시오")
            }
            tapList = [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]]
        }

        var configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mtgrec",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: input.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // true 로 두면 탭에 소리가 흐를 때만 클럭이 돈다. 상대가 조용한 동안
            // 마이크 트랙까지 멈춰서 내 발언이 통째로 사라진다.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if !tapList.isEmpty {
            configuration[kAudioAggregateDeviceTapListKey] = tapList
        }

        let aggregateStatus = AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            throw RecorderError.message("aggregate device 생성 실패 (status \(aggregateStatus))")
        }

        // sysOnly 여도 입력 장치는 aggregate 의 클럭으로 남긴다. 탭만으로 aggregate 를
        // 만들면 상대가 조용할 때 클럭이 멈춘다. 마이크 샘플은 IOProc 에서 버리고
        // 파일로는 쓰지 않는다.
        if !sysOnly {
            micWriter = try TrackWriter(name: "mic", speaker: "나", directory: directory,
                                        sourceRate: sourceRate, targetRate: targetRate, ring: micRing,
                                        writeSidecar: writeSidecar)
        }
        if !micOnly {
            sysWriter = try TrackWriter(name: "sys", speaker: "상대", directory: directory,
                                        sourceRate: sourceRate, targetRate: targetRate, ring: sysRing,
                                        writeSidecar: writeSidecar)
        }

        let micRing = self.micRing
        let sysRing = self.sysRing
        let expectsSystemTrack = !micOnly
        let keepsMic = !sysOnly

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            for (index, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / channels
                let samples = data.assumingMemoryBound(to: Float32.self)

                // buffer[0] 이 마이크, buffer[1] 이 시스템 탭이다. 탭은 스테레오라 모노로 접는다.
                let ring: RingBuffer? = index == 0 ? (keepsMic ? micRing : nil) : (expectsSystemTrack ? sysRing : nil)
                guard let ring else { continue }

                if channels == 1 {
                    ring.write(samples, count: frames)
                } else {
                    var mono = [Float](repeating: 0, count: frames)
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for channel in 0..<channels {
                            sum += samples[frame * channels + channel]
                        }
                        mono[frame] = sum / Float(channels)
                    }
                    mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }
                }
            }
        }
        guard ioStatus == noErr, let ioProcID else {
            throw RecorderError.message("IOProc 생성 실패 (status \(ioStatus))")
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            throw RecorderError.message("캡처 시작 실패 (status \(startStatus)). 마이크 권한을 확인하십시오")
        }

        running = true
        let thread = Thread { [weak self] in
            while let self, self.running {
                Thread.sleep(forTimeInterval: 0.25)
                try? self.micWriter?.flush()
                try? self.sysWriter?.flush()
            }
        }
        thread.name = "mtgrec.writer"
        thread.start()
        writerThread = thread
    }

    /// 남은 버퍼를 마저 쓰고 장치를 정리한 뒤 트랙 요약을 준다.
    func stop() -> [Session.Track] {
        running = false
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }

        // 정지 시점에 링버퍼에 남은 것을 끝까지 비운다.
        for _ in 0..<20 {
            try? micWriter?.flush()
            try? sysWriter?.flush()
            if micRing.pending == 0 && sysRing.pending == 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        micWriter?.close()
        sysWriter?.close()

        return [micWriter, sysWriter].compactMap { writer -> Session.Track? in
            guard let writer else { return nil }
            return Session.Track(name: writer.name,
                                 speaker: writer.speaker,
                                 file: writer.url.lastPathComponent,
                                 frames: writer.framesWritten,
                                 seconds: writer.seconds,
                                 peak: writer.peak)
        }
    }

    var droppedFrames: Int { micRing.droppedFrames + sysRing.droppedFrames }
}
