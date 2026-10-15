//
//  CircuitBreaker.swift
//  StockMenuBar
//
//  熔断器:连续失败达到阈值后熔断一段时间,到期半开放行单个探测请求。
//  @author ixxxxoooo
//

import Foundation

struct CircuitBreaker: Sendable {
    enum State: Equatable, Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    /// 触发熔断的连续失败次数
    let failureThreshold: Int
    /// 熔断持续时间(秒)
    let openDuration: TimeInterval

    private(set) var state: State = .closed
    private(set) var consecutiveFailures = 0
    private var probeInFlight = false

    init(failureThreshold: Int = 3, openDuration: TimeInterval = 30) {
        self.failureThreshold = failureThreshold
        self.openDuration = openDuration
    }

    /// 当前是否允许发起请求(不改变状态,用于排序/筛选)
    func isAvailable(now: Date) -> Bool {
        switch state {
        case .closed: return true
        case .open(let until): return now >= until
        case .halfOpen: return !probeInFlight
        }
    }

    /// 真正发起请求前调用:熔断到期则转半开,半开状态占用探测名额
    mutating func beginAttempt(now: Date) {
        switch state {
        case .closed: break
        case .open(let until):
            if now >= until {
                state = .halfOpen
                probeInFlight = true
            }
        case .halfOpen:
            probeInFlight = true
        }
    }

    /// 记录成功:关闭熔断
    mutating func recordSuccess() {
        state = .closed
        consecutiveFailures = 0
        probeInFlight = false
    }

    /// 记录失败:半开失败立即重新熔断,闭合状态累计达到阈值后熔断
    mutating func recordFailure(now: Date) {
        probeInFlight = false
        consecutiveFailures += 1
        if state == .halfOpen || consecutiveFailures >= failureThreshold {
            state = .open(until: now.addingTimeInterval(openDuration))
        }
    }
}
