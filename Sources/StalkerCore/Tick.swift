/// Assemble one observation. Pure apart from the injected probes, so every
/// branch is testable without touching a real macOS API. Spec §5.2.
public func makeSample(now: Int, previous: Sample?, config: TickConfig, probes: Probes) -> Sample {
    // A locked screen means you left; nothing else about the machine matters.
    if probes.lock.isScreenLocked() {
        return Sample(at: now, kind: .locked, bundleId: nil, appName: nil,
                      contextKind: nil, context: nil, title: nil,
                      hadInput: false, engaged: false)
    }

    // No frontmost application (login window, fast user switch) is missing data,
    // not activity, so it is recorded as a gap rather than attributed to anything.
    guard let focus = probes.focus.frontmost() else {
        return Sample(at: now, kind: .gap, bundleId: nil, appName: nil,
                      contextKind: nil, context: nil, title: nil,
                      hadInput: false, engaged: false)
    }

    let inputIdleSecs = probes.idle.inputIdleSeconds()
    let hadInput = inputIdleSecs < Double(config.samplePeriod)

    // The engagement check is a tiebreaker, reached only once the no-input
    // threshold trips — so it costs nothing while you are typing. Spec §5.4.
    var engaged = false
    var kind = Kind.app
    if inputIdleSecs > Double(config.idleThreshold) {
        engaged = probes.engagement.isEngaged(pid: focus.pid)
        kind = engaged ? .app : .idle
    }

    // Capture context when active, and once on the transition into idle.
    // While idle continues, nothing can have changed — with no input, focus and
    // URL cannot move — so the previous context is carried forward rather than
    // re-queried. Carrying it forward also keeps IntervalKey stable; returning
    // nil would open a new interval on every idle tick. Spec §5.2.
    let enteringIdle = (kind == .idle) && (previous?.kind != .idle)
    let shouldCapture = (kind == .app) || enteringIdle

    var contextKind: ContextKind?
    var context: String?
    var title: String?

    if shouldCapture {
        // Terminals are served by the courier, not by Accessibility: macOS
        // exposes no way to ask which terminal tab has focus. Spec §5.3.
        if let bundle = focus.bundleId, config.terminalBundleIds.contains(bundle),
           let reading = probes.courier.newest(now: now) {
            contextKind = .cwd
            context = reading.cwd
        } else {
            switch probes.context.context(for: focus) {
            case .none:
                break
            case .denied:
                contextKind = .denied
            case .value(let k, let v, let ttl):
                contextKind = k
                context = v
                title = ttl
            }
        }
    } else {
        contextKind = previous?.contextKind
        context = previous?.context
        title = previous?.title
    }

    return Sample(at: now, kind: kind, bundleId: focus.bundleId, appName: focus.appName,
                  contextKind: contextKind, context: context, title: title,
                  hadInput: hadInput, engaged: engaged)
}
