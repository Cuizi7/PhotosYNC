public enum GlobalStatus: String, CaseIterable, Sendable {
    case unconfigured, error, paused, waiting, running, completed

    /// Configuration includes enabled sources or independent historical Live Photo work.
    /// Priority is fixed: unconfigured, then anything a person must handle (missing Photos
    /// authorization and engine-level errors), then pause, then waiting for a source, then work.
    /// A missing Photos permission is not a wait for a directory to come back: only the user can
    /// grant it, so it must not hide behind the waiting symbol.
    public static func resolve(configured: Bool, error: Bool, paused: Bool, waiting: Bool, running: Bool, authorized: Bool = true) -> Self {
        guard configured else { return .unconfigured }
        if !authorized { return .error }
        if error { return .error }
        if paused { return .paused }
        if waiting { return .waiting }
        return running ? .running : .completed
    }

    public var symbol: String {
        switch self {
        case .unconfigured: return "photo"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        }
    }

    public var description: String {
        switch self {
        case .unconfigured: return "未配置来源"
        case .error: return "同步异常"
        case .paused: return "已暂停"
        case .waiting: return "等待中"
        case .running: return "正在同步"
        case .completed: return "已完成"
        }
    }
}
