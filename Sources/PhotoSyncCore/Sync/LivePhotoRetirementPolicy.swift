import Foundation

public enum LivePhotoRetirementDecision: Equatable, Sendable { case eligible, retain(reasons: [String]) }

public enum LivePhotoRetirementPolicy {
    public static func evaluate(old: LivePhotoPreservationSnapshot, target: LivePhotoPreservationSnapshot, resourcePreserved: Bool) -> LivePhotoRetirementDecision {
        var reasons = [String]()
        if !resourcePreserved { reasons.append("原资源尚未核实") }
        if !old.retirementInformationIsKnown || !target.retirementInformationIsKnown { reasons.append("受保护信息尚未核实") }
        if old.hasAdjustments != .value(false) || old.hasExtraResources != .value(false) || old.isSharedAlbum != .value(false) { reasons.append("旧项目包含不能迁移的内容或关联") }
        if old.creationDate != target.creationDate || old.location != target.location { reasons.append("日期或位置存在差异") }
        if !preserved(old.favorite, in: target.favorite) || !preserved(old.hidden, in: target.hidden) { reasons.append("收藏或隐藏状态未保留") }
        if old.rating != target.rating || old.caption != target.caption { reasons.append("文字或评分信息未保留") }
        if !subset(old.keywords, target.keywords) || !subset(old.albumIDs, target.albumIDs) { reasons.append("关键字或相册关系未保留") }
        return reasons.isEmpty ? .eligible : .retain(reasons: reasons)
    }
    private static func preserved(_ old: PreservedField<Bool>, in target: PreservedField<Bool>) -> Bool {
        if old == .value(true) { return target == .value(true) }
        return old.isKnown && target.isKnown
    }
    private static func subset(_ old: PreservedField<[String]>, _ target: PreservedField<[String]>) -> Bool {
        func values(_ field: PreservedField<[String]>) -> [String]? { switch field { case .value(let v): return v; case .emptyOrNotApplicable: return []; case .unknown: return nil } }
        guard let a = values(old), let b = values(target) else { return false }
        return Set(a).isSubset(of: Set(b))
    }
    public static func mergeForCreation(photo: LivePhotoPreservationSnapshot, motion: LivePhotoPreservationSnapshot) -> LivePhotoPreservationSnapshot {
        var result = photo
        result.favorite = or(photo.favorite, motion.favorite); result.hidden = or(photo.hidden, motion.hidden)
        result.albumIDs = union(photo.albumIDs, motion.albumIDs); result.keywords = union(photo.keywords, motion.keywords)
        result.rating = merge(photo.rating, motion.rating); result.title = merge(photo.title, motion.title); result.caption = merge(photo.caption, motion.caption)
        return result
    }
    private static func merge<T>(_ a: PreservedField<T>, _ b: PreservedField<T>) -> PreservedField<T> {
        if a == b { return a }; if a == .emptyOrNotApplicable { return b }; if b == .emptyOrNotApplicable { return a }; return .unknown
    }
    private static func or(_ a: PreservedField<Bool>, _ b: PreservedField<Bool>) -> PreservedField<Bool> {
        if a == .value(true) || b == .value(true) { return .value(true) }
        if a.isKnown && b.isKnown { return .value(false) }; return .unknown
    }
    private static func union(_ a: PreservedField<[String]>, _ b: PreservedField<[String]>) -> PreservedField<[String]> {
        func values(_ f: PreservedField<[String]>) -> [String]? { switch f { case .value(let v): return v; case .emptyOrNotApplicable: return []; case .unknown: return nil } }
        guard let a = values(a), let b = values(b) else { return .unknown }; return .value(Set(a + b).sorted())
    }
    static var empty: LivePhotoPreservationSnapshot {
        var s = LivePhotoPreservationSnapshot(revision: "new")
        s.creationDate = .emptyOrNotApplicable; s.location = .emptyOrNotApplicable; s.favorite = .value(false); s.hidden = .value(false)
        s.rating = .emptyOrNotApplicable; s.title = .emptyOrNotApplicable; s.caption = .emptyOrNotApplicable; s.keywords = .value([]); s.albumIDs = .value([])
        s.hasAdjustments = .value(false); s.hasExtraResources = .value(false); s.isSharedAlbum = .value(false)
        return s
    }
}
