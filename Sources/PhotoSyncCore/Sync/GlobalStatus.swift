public enum GlobalStatus: String, CaseIterable, Sendable {
    case preparing, error, paused, waiting, running, completed

    /// Global blocks, pause and unknown writes precede real work; local waits do not hide it.
    public static func resolve(configured: Bool, error: Bool, paused: Bool, waiting: Bool, running: Bool,
                               authorized: Bool = true, preparing: Bool = false, unknownMutation: Bool = false,
                               requiresAttention: Bool = false) -> Self {
        if !authorized || error || !configured { return .error }
        if paused { return .paused }
        if unknownMutation { return .waiting }
        if running { return .running }
        if preparing { return .preparing }
        if requiresAttention { return .error }
        return waiting ? .waiting : .completed
    }

    public var symbol: String {
        switch self {
        case .preparing: return "hourglass"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        }
    }

    public var description: String {
        switch self {
        case .preparing: return "正在准备"
        case .error: return "需要处理"
        case .paused: return "已暂停"
        case .waiting: return "等待恢复"
        case .running: return "正在同步"
        case .completed: return "同步完成"
        }
    }
}
