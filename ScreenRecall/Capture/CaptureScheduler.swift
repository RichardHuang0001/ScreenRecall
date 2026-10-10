import Foundation

/// 唯一的低频定时器；事件处理只投递触发信号。
actor CaptureScheduler {
    private let interval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?

    init(intervalSeconds: Int = 45) {
        precondition(intervalSeconds > 0)
        interval = .seconds(intervalSeconds)
    }

    func start(tick: @escaping @Sendable () -> Void) {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ScreenRecall.capture.timer"))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        source.setEventHandler(handler: tick)
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
