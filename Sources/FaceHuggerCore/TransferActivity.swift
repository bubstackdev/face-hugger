import Foundation

public enum TransferPhase: String, Codable, Sendable {
    case validating, scanning, comparing, hashing, negotiating, uploading, committing, verifying, retryWaiting
    public var label: String {
        switch self {
        case .validating: "Validating upload"
        case .scanning: "Checking source files"
        case .comparing: "Comparing repository"
        case .hashing: "Hashing files"
        case .negotiating: "Preparing transfer"
        case .uploading: "Uploading"
        case .committing: "Committing files"
        case .verifying: "Verifying results"
        case .retryWaiting: "Waiting to retry"
        }
    }
}

public enum TransferBodyKind: String, Sendable {
    case metadata, file, commit
    var isUpload: Bool { self != .metadata }
}
public enum TransferRetryReason: String, Codable, Sendable {
    case timeout, connection, rateLimit, serverError
    public var label: String {
        switch self {
        case .timeout: "Request timed out"
        case .connection: "Connection interrupted"
        case .rateLimit: "Service rate limit"
        case .serverError: "Temporary server error"
        }
    }
}
public struct TransferRequest: Equatable, Sendable {
    public let id: UUID
    public let attempt: Int
    public let maximumAttempts: Int
    public let bodyKind: TransferBodyKind
}
public struct TransferRetry: Equatable, Sendable {
    public let request: TransferRequest
    public let reason: TransferRetryReason
    public let resumesAt: Date
    public var nextAttempt: Int { request.attempt + 1 }
    public func remainingSeconds(at date: Date) -> Int { Int(ceil(max(0, resumesAt.timeIntervalSince(date)))) }
}

/// These events deliberately contain no request addresses, headers, tokens, or response bodies.
public enum NativeTransferEvent: Sendable {
    case started(TransferRequest)
    case bodyBytes(requestID: UUID, attempt: Int, cumulative: Int64)
    case finished(requestID: UUID, attempt: Int)
    case waiting(TransferRetry)
    case waitCancelled(requestID: UUID, attempt: Int)
}

public struct TransferTransportSummary: Codable, Equatable, Sendable {
    public var requestAttempts = 0
    public var retryAttempts = 0
    public var retryWaits = 0
    public var cancelledRetryWaits = 0
    public var retryReasons: [TransferRetryReason: Int] = [:]
    public var requestBodyBytes: Int64 = 0
    public var uploadBodyBytes: Int64 = 0
}

public struct TransferLiveActivity: Equatable, Sendable {
    public var phase: TransferPhase?
    public var currentFile: String?
    public var retry: TransferRetry?
    public var transport: TransferTransportSummary?
    public var uploadBodyBytesPerSecond: Double?
}

/// A bounded monotonic window. Wall-clock dates are never used to calculate throughput.
struct TransferRateWindow: Sendable {
    private var samples: [(time: Double, bytes: Int64)] = []
    private var lastIncrease: Double?
    mutating func reset() { samples.removeAll(keepingCapacity: true); lastIncrease = nil }
    mutating func start(at time: Double?, bytes: Int64) {
        reset()
        if let time, time.isFinite { samples = [(time, bytes)] }
    }
    mutating func observe(at time: Double?, bytes: Int64) {
        guard let time, time.isFinite, let last = samples.last, time >= last.time, bytes >= last.bytes else { return }
        if bytes > last.bytes { lastIncrease = time }
        if time == last.time { samples[samples.count - 1] = (time, bytes) }
        else { samples.append((time, bytes)) }
        while samples.count > 2 && samples[1].time < time - 5 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }
    func rate(at time: Double?) -> Double? {
        guard let time, let lastIncrease, time >= lastIncrease, time - lastIncrease <= 2,
              let first = samples.first, let last = samples.last, last.time - first.time >= 0.25,
              last.bytes > first.bytes else { return nil }
        let value = Double(last.bytes - first.bytes) / (last.time - first.time)
        return value.isFinite && value > 0 ? value : nil
    }
}

struct TransferTransportTracker: Sendable {
    private(set) var summary = TransferTransportSummary()
    private var active: TransferRequest?
    private var highWater: Int64 = 0
    private var rateWindow = TransferRateWindow()
    private(set) var retry: TransferRetry?
    private(set) var rate: Double?

    mutating func apply(_ event: NativeTransferEvent, at time: Double?) {
        switch event {
        case .started(let request):
            guard request.attempt > 0, request.attempt <= request.maximumAttempts, request.maximumAttempts <= 3,
                  active != request else { return }
            active = request; highWater = 0; retry = nil
            summary.requestAttempts += 1
            if request.attempt > 1 { summary.retryAttempts += 1 }
            rateWindow.start(at: request.bodyKind.isUpload ? time : nil, bytes: summary.uploadBodyBytes)
        case .bodyBytes(let id, let attempt, let cumulative):
            guard let active, active.id == id, active.attempt == attempt, cumulative >= 0 else { return }
            let delta = max(0, cumulative - highWater)
            highWater = max(highWater, cumulative)
            summary.requestBodyBytes = Self.add(summary.requestBodyBytes, delta)
            if active.bodyKind.isUpload {
                summary.uploadBodyBytes = Self.add(summary.uploadBodyBytes, delta)
                if delta > 0 { rateWindow.observe(at: time, bytes: summary.uploadBodyBytes) }
            }
        case .finished(let id, let attempt):
            guard active?.id == id, active?.attempt == attempt else { return }
            active = nil; rateWindow.reset()
        case .waiting(let wait):
            guard wait.request.attempt < wait.request.maximumAttempts, retry != wait else { return }
            retry = wait; rateWindow.reset()
            summary.retryWaits += 1
            summary.retryReasons[wait.reason, default: 0] += 1
        case .waitCancelled(let id, let attempt):
            guard retry?.request.id == id, retry?.request.attempt == attempt else { return }
            retry = nil; summary.cancelledRetryWaits += 1; rateWindow.reset()
        }
        refresh(at: time)
    }
    mutating func refresh(at time: Double?) { rate = active?.bodyKind.isUpload == true && retry == nil ? rateWindow.rate(at: time) : nil }
    mutating func suspendRate() { rateWindow.reset(); rate = nil }
    mutating func finish() { active = nil; retry = nil; suspendRate() }
    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

enum TransferRetryPolicy {
    static func delay(base: Duration, failedAttempt: Int, header: String?, now: Date) -> Duration {
        let backoff = base * (1 << max(0, min(1, failedAttempt - 1)))
        var seconds: Double = 0
        if let header {
            let raw = header.trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(raw) { seconds = min(30, number) }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                for format in ["EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'", "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'", "EEE MMM d HH':'mm':'ss yyyy"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: raw) { seconds = min(30, max(0, date.timeIntervalSince(now))); break }
                }
            }
        }
        return max(.zero, max(backoff, .seconds(seconds)))
    }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
