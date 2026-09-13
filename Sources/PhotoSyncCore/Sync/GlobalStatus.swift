public enum GlobalStatus: String, CaseIterable, Sendable {
    case unconfigured, error, paused, waiting, running, completed

    public static func resolve(configured: Bool, error: Bool, paused: Bool, waiting: Bool, running: Bool) -> Self {
        guard configured else { return .unconfigured }
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
        case .error: return "需要处理错误"
        case .paused: return "已暂停"
        case .waiting: return "等待恢复"
        case .running: return "正在同步"
        case .completed: return "已完成"
        }
    }
}
