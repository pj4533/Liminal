//
//  DropPipelines.swift
//  Liminal
//
//  Drop twins of the effects pipelines (docs/decisions/transitions.md T48): the same fragment functions
//  specialized with the function constants kDropTx, kDropColour, kDropFinisher and kDropStyle for one drop,
//  compiled off the main thread when the drop is planned (`announce`, many seconds ahead) and bound while
//  it runs. Until a twin is ready the plain pipeline is used: the drop then lacks its colour layer,
//  finisher and the Sort / Punch taps, nothing else. Shared with scripts/shader-bench.swift.
//

import Metal
import Synchronization

extension EffectsUniforms {
    /// This frame needs a drop pipeline: a drop style or a drop colour layer / finisher is running.
    nonisolated var needsDropPipeline: Bool { transitionProgress > 0 && (txStyle > 12.5 || txLayers > 0.5) }
}

nonisolated final class DropPipelines: Sendable {
    /// One specialization: the drop's colour layer, finisher and stage B style (Sort, Punch, Shutter, Static).
    struct Key: Hashable, Sendable {
        var colour: Int, finisher: Int, style: Int

        init(colour: Int, finisher: Int, style: Int) {
            self.colour = colour; self.finisher = finisher
            self.style = [18, 19, 23, 24].contains(style) ? style : 0
        }
        init(_ spec: TransitionSpec) {
            self.init(colour: spec.drop?.colour.rawValue ?? 0, finisher: spec.drop?.finisher.rawValue ?? 0,
                      style: spec.style.rawValue)
        }
        init(_ u: EffectsUniforms) {
            let layers = Int(u.txLayers + 0.5)
            self.init(colour: layers % 8, finisher: layers / 8, style: Int(u.txStyle + 0.5))
        }
    }

    private struct Base { let descriptor: MTLRenderPipelineDescriptor; let name: String }
    private struct State: @unchecked Sendable {
        var bases: [Base] = []
        var device: MTLDevice?
        var library: MTLLibrary?
        var twins: [Key: [String: MTLRenderPipelineState]] = [:]
        var order: [Key] = []
        /// Pipelines bound since the last announcement, and twins already being compiled.
        var used: Set<String> = []
        var pending: Set<String> = []
        /// The latest announced drop: a pipeline first bound after its announcement gets its twin then.
        var announced: Key?
    }
    private let state = Mutex(State())
    /// Distinct drops kept compiled (each key holds one twin per registered pipeline).
    static let keep = 6

    /// Live instances, so the scheduler can announce a drop to every renderer.
    private static let live = Mutex<[WeakBox]>([])
    private struct WeakBox: @unchecked Sendable { weak var value: DropPipelines? }

    init() { Self.live.withLock { $0.removeAll { $0.value == nil }; $0.append(WeakBox(value: self)) } }

    /// A fragment function specialized for `key` (nil key: the plain function). Every effects fragment uses
    /// the constants, so Metal only builds pipelines from specialized functions: the plain ones come from here.
    static func function(_ library: MTLLibrary, name: String, key: Key? = nil) -> MTLFunction? {
        guard library.functionNames.contains(name) else { return nil }
        let values = MTLFunctionConstantValues()
        var on = key != nil
        values.setConstantValue(&on, type: .bool, index: 0)
        if let key {
            var c = Int32(key.colour), f = Int32(key.finisher), s = Int32(key.style)
            values.setConstantValue(&c, type: .int, index: 1)
            values.setConstantValue(&f, type: .int, index: 2)
            values.setConstantValue(&s, type: .int, index: 3)
        }
        if let f = try? library.makeFunction(name: name, constantValues: values) { return f }
        return library.makeFunction(name: name)   // a library without the constants (older shaders)
    }

    /// Registers a plain pipeline (its descriptor carries `name` as its label) for drop twins.
    func register(device: MTLDevice, library: MTLLibrary, descriptor: MTLRenderPipelineDescriptor, name: String) {
        guard let copy = descriptor.copy() as? MTLRenderPipelineDescriptor else { return }
        state.withLock { s in
            s.device = device; s.library = library
            s.bases.append(Base(descriptor: copy, name: name))
        }
    }

    /// A drop was planned: build its twins on every live renderer (asynchronous).
    static func announce(_ spec: TransitionSpec) {
        guard spec.drop != nil else { return }
        let key = Key(spec)
        // Specializing the functions is synchronous Metal compilation (about 40 ms each): never on the main
        // thread (it stalled the macOS render 350-410 ms per drop).
        // Only the pipelines the renderer has been binding are specialized (one to three, not all 18: compiling
        // every variant at once coincided with Core Audio overloads in the Simulator). A pipeline first bound
        // after the announcement is compiled when it is first bound, and the plain one is used meanwhile; before
        // anything has been bound (right after Play) every pipeline waits for its first bind.
        let targets = live.withLock { $0.compactMap(\.value) }
        DispatchQueue.global(qos: .background).async { for t in targets { t.prepare(key) } }
    }

    /// Builds the twins for `key` (asynchronously unless `wait`): for the pipelines bound since the last
    /// announcement, or for `only` (all registered ones when `wait`, the offline tools).
    func prepare(_ key: Key, wait: Bool = false, only: String? = nil) {
        let job: (MTLDevice, MTLLibrary, [Base])? = state.withLock { s in
            guard let d = s.device, let l = s.library else { return nil }
            if s.twins[key] == nil {
                s.twins[key] = [:]
                s.order.append(key)
                while s.order.count > Self.keep { s.twins[s.order.removeFirst()] = nil }
            }
            if only == nil && !wait {
                s.announced = key
                // Nothing bound yet (the first drop is announced right after Play): compile each pipeline when it
                // is first bound, one at a time, instead of all of them at once (that burst overloaded Core Audio).
                if s.used.isEmpty { return nil }
            }
            let names: Set<String> = only.map { [$0] } ?? (wait ? Set(s.bases.map(\.name)) : s.used)
            if only == nil { s.used = [] }
            let todo = s.bases.filter { b in
                names.contains(b.name) && s.twins[key]?[b.name] == nil && !s.pending.contains("\(key)|\(b.name)")
            }
            for b in todo { s.pending.insert("\(key)|\(b.name)") }
            return todo.isEmpty ? nil : (d, l, todo)
        }
        guard let (device, library, bases) = job else { return }
        for base in bases {
            guard let twin = base.descriptor.copy() as? MTLRenderPipelineDescriptor,
                  let f = Self.function(library, name: base.name, key: key) else { continue }
            twin.fragmentFunction = f
            twin.label = base.name + "+drop"
            let store: @Sendable (MTLRenderPipelineState?) -> Void = { [self] st in
                state.withLock { s in
                    s.pending.remove("\(key)|\(base.name)")
                    if let st, s.twins[key] != nil { s.twins[key]?[base.name] = st }
                }
            }
            if wait { store(try? device.makeRenderPipelineState(descriptor: twin)) }
            else { device.makeRenderPipelineState(descriptor: twin) { st, _ in store(st) } }
        }
    }

    /// `plain`'s drop twin when the frame needs one and it is ready, else `plain`.
    func pipeline(for plain: MTLRenderPipelineState, uniforms: EffectsUniforms) -> MTLRenderPipelineState {
        guard let name = plain.label else { return plain }
        guard uniforms.needsDropPipeline else {
            let late: Key? = state.withLock { s in
                guard s.used.insert(name).inserted, let k = s.announced, s.twins[k] != nil, s.twins[k]?[name] == nil,
                      !s.pending.contains("\(k)|\(name)") else { return nil }
                return k
            }
            if let late { DispatchQueue.global(qos: .background).async { [self] in prepare(late, only: name) } }
            return plain
        }
        let key = Key(uniforms)
        var missing = false
        let twin: MTLRenderPipelineState? = state.withLock { s in
            if let t = s.twins[key]?[name] { return t }
            missing = !s.pending.contains("\(key)|\(name)")
            return nil
        }
        if missing { DispatchQueue.global(qos: .userInitiated).async { [self] in prepare(key, only: name) } }
        return twin ?? plain
    }
}
