import Foundation

/// 唯一的低频定时器；事件处理只投递触发信号。
actor CaptureScheduler {
    private var interval: DispatchTimeInterval
    private(set) var intervalSeconds: Int
    private var timer: DispatchSourceTimer?
    private var lastTick: (@Sendable () -> Void)?

    init(intervalSeconds: Int = 45) {
        precondition(intervalSeconds > 0)
        self.intervalSeconds = intervalSeconds
        interval = .seconds(intervalSeconds)
    }

    func start(tick: @escaping @Sendable () -> Void) {
        lastTick = tick
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ScreenRecall.capture.timer"))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        source.setEventHandler(handler: tick)
        timer = source
        source.resume()
    }

    func updateInterval(seconds: Int) {
        guard seconds > 0 else { return }
        intervalSeconds = seconds
        interval = .seconds(seconds)
        if timer != nil, let tick = lastTick {
            stop()
            start(tick: tick)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
