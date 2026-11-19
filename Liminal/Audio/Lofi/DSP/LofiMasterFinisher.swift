import AudioKit
import AudioToolbox
import AVFoundation
import Foundation

/// Render-thread context: the kernel and the buffers used to pull input. Owned by the audio unit
/// and reached from the render block through an unretained reference.
nonisolated final class LofiMasterRenderContext: @unchecked Sendable {
    let kernel: LofiMasterKernel
    private(set) var capacity: Int
    private(set) var left: UnsafeMutablePointer<Float>
    private(set) var right: UnsafeMutablePointer<Float>
    let inputList: UnsafeMutableAudioBufferListPointer

    init(kernel: LofiMasterKernel, capacity: Int) {
        self.kernel = kernel
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        inputList = AudioBufferList.allocate(maximumBuffers: 2)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        free(inputList.unsafeMutablePointer)
    }

    /// Not realtime: called from allocateRenderResources only.
    func ensureCapacity(_ frames: Int) {
        guard frames > capacity else { return }
        left.deallocate()
        right.deallocate()
        capacity = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
    }

    @inline(__always)
    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: AUAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>,
                pull: AURenderPullInputBlock?) -> AUAudioUnitStatus {
        let n = Int(frameCount)
        guard let pull else { return kAudioUnitErr_NoConnection }
        guard n <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
        let bytes = UInt32(n * MemoryLayout<Float>.stride)
        inputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
        inputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
        var pullFlags = AudioUnitRenderActionFlags()
        let status = pull(&pullFlags, timestamp, frameCount, 0, inputList.unsafeMutablePointer)
        guard status == noErr else { return status }
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard outputs.count >= 2, inputList.count >= 2,
              let inL = inputList[0].mData?.assumingMemoryBound(to: Float.self),
              let inR = inputList[1].mData?.assumingMemoryBound(to: Float.self) else {
            return kAudioUnitErr_FormatNotSupported
        }
        if outputs[0].mData == nil { outputs[0].mData = inputList[0].mData }
        if outputs[1].mData == nil { outputs[1].mData = inputList[1].mData }
        guard let outL = outputs[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = outputs[1].mData?.assumingMemoryBound(to: Float.self) else {
            return kAudioUnitErr_FormatNotSupported
        }
        outputs[0].mDataByteSize = bytes
        outputs[1].mDataByteSize = bytes
        kernel.process(inL: inL, inR: inR, outL: outL, outR: outR, count: n)
        return noErr
    }
}

/// In-process effect unit around `LofiMasterKernel`: stereo, float, non-interleaved, one bus each way.
nonisolated final class LofiMasterAudioUnit: AUAudioUnit, @unchecked Sendable {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6C_66_6D_66,          // 'lfmf'
        componentManufacturer: 0x4C_6D_6E_6C,     // 'Lmnl'
        // The sandboxed app may only load in-process components marked sandbox safe.
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0)

    /// Registers the subclass once per process.
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(LofiMasterAudioUnit.self, as: componentDescription,
                                     name: "Liminal: Lo-Fi Master", version: 1)
        return true
    }()

    let context: LofiMasterRenderContext
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    var kernel: LofiMasterKernel { context.kernel }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let rate = 48_000.0
        let frames = 4096
        context = LofiMasterRenderContext(kernel: LofiMasterKernel(sampleRate: rate, maximumFrames: frames),
                                          capacity: frames)
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 2
        outputBus.maximumChannelCount = 2
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = AUAudioFrameCount(frames)
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }
    override var channelCapabilities: [NSNumber]? { [2, 2] }

    override var latency: TimeInterval {
        Double(kernel.latencyFrames) / kernel.sampleRate
    }

    override func allocateRenderResources() throws {
        let format = outputBus.format
        guard format.channelCount == 2, inputBus.format.channelCount == 2,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              inputBus.format.sampleRate == format.sampleRate else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        context.ensureCapacity(frames)
        kernel.prepare(sampleRate: format.sampleRate, maximumFrames: frames)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let context = Unmanaged.passUnretained(self.context)
        return { flags, timestamp, frameCount, _, output, _, pull in
            context._withUnsafeGuaranteedRef {
                $0.render(flags: flags, timestamp: timestamp, frameCount: frameCount, output: output, pull: pull)
            }
        }
    }
}

/// AudioKit node around the master finisher unit. When the unit cannot be created the node is a
/// unity-gain pass-through (`isOperational == false`, zero latency) so the graph still builds.
nonisolated final class LofiMasterFinisher: Node, @unchecked Sendable {
    let input: Node
    let avAudioNode: AVAudioNode
    let isOperational: Bool
    private let unit: LofiMasterAudioUnit?
    var connections: [Node] { [input] }

    convenience init(_ input: Node, settings: LofiMasterSettings = .passthrough) {
        self.init(input, settings: settings, forceFallback: false)
    }

    init(_ input: Node, settings: LofiMasterSettings, forceFallback: Bool) {
        self.input = input
        let instance = forceFallback ? nil : Self.instantiate()
        if let instance, let unit = instance.auAudioUnit as? LofiMasterAudioUnit {
            self.unit = unit
            avAudioNode = instance
            isOperational = true
            unit.kernel.apply(settings, ramp: 0)
        } else {
            unit = nil
            avAudioNode = AVAudioMixerNode()
            isOperational = false
        }
    }

    /// AVAudioUnit.instantiate with its completion handler. The registered in-process subclass completes
    /// before the call returns; the bounded wait only guards against a callback that never arrives.
    private static func instantiate() -> AVAudioUnit? {
        guard LofiMasterAudioUnit.registered else { return nil }
        final class Box: @unchecked Sendable { var unit: AVAudioUnit? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // A registered subclass exists only in this process, so macOS must not try out-of-process loading.
        // visionOS has no such option and always loads registered subclasses in process.
        #if os(macOS)
        let options: AudioComponentInstantiationOptions = .loadInProcess
        #else
        let options: AudioComponentInstantiationOptions = []
        #endif
        AVAudioUnit.instantiate(with: LofiMasterAudioUnit.componentDescription, options: options) { unit, _ in
            box.unit = unit
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else { return nil }
        return box.unit
    }

    /// Hands new settings to the render thread; they start at the next block and ramp over `ramp` seconds.
    func apply(_ settings: LofiMasterSettings, ramp: Double) {
        unit?.kernel.apply(settings, ramp: ramp)
    }

    var meters: LofiMasterMeters { unit?.kernel.meters ?? .zero }
    func resetMeters() { unit?.kernel.resetMeters() }
    func startTrace(capacity: Int) { unit?.kernel.startTrace(capacity: capacity) }
    func takeTrace() -> [LofiMasterTracePoint] { unit?.kernel.takeTrace() ?? [] }

    /// Seconds of delay the unit adds (zero for the pass-through fallback).
    var latency: Double { unit?.latency ?? 0 }
    var latencyFrames: Int { unit?.kernel.latencyFrames ?? 0 }
}
