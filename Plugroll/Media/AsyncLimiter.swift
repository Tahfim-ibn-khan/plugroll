/// Caps how many jobs run at once. Waiting jobs are served newest-first, so the
/// cells currently on screen get their thumbnails before ones scrolled past.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() {
            next.resume() // hand the slot straight to the next job
        } else {
            running -= 1
        }
    }
}
