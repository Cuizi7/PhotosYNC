import SwiftUI
import PhotoSyncCore

/// One rich line gives the whole path a single head-truncation boundary.
struct SourcePathLabel: View {
    let url: URL

    private var pathText: Text {
        let path = url.path
        let basename = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        let prefix = path == "/" ? "" : String(path.dropLast(basename.count))
        return Text(prefix).font(.caption).foregroundColor(.secondary)
            + Text(basename).font(.caption).foregroundColor(.primary)
    }

    var body: some View {
        pathText
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(url.path)
            .accessibilityLabel(url.path)
    }
}

/// Directory availability is a source state; only file-associated diagnostics contribute
/// to the problem count. Both the compact row and its details use the same two layers.
private struct SourceIssuePresentation {
    let sourceURL: URL
    let issues: [SourceIssueDetail]
    let recoveryPending: Bool
    var isScanningDirectory: Bool = false

    var directoryStatus: String? {
        let directories = issues.filter { $0.kind == .sourceAvailability }
        if directories.contains(where: { $0.path == sourceURL.path }) {
            return "来源目录不可用，等待恢复"
        }
        if !directories.isEmpty { return "部分子目录不可用" }
        guard recoveryPending else { return nil }
        return isScanningDirectory ? "正在扫描目录" : "目录扫描尚未完成，稍后继续"
    }

    var fileProblemCount: Int {
        issues.filter { $0.kind == .file || $0.kind == .submission }.count
    }

    func summary(fallback: String) -> String {
        let count = fileProblemCount > 0 ? "发现 \(fileProblemCount) 项问题" : nil
        let parts = [directoryStatus, count].compactMap { $0 }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }
}

struct SourceRowLabel: View {
    let url: URL
    let status: String
    var issues: [SourceIssueDetail] = []
    var recoveryPending: Bool = false
    var isScanningDirectory: Bool = false

    private var presentation: SourceIssuePresentation {
        SourceIssuePresentation(sourceURL: url, issues: issues, recoveryPending: recoveryPending,
            isScanningDirectory: isScanningDirectory)
    }

    var statusText: String { presentation.summary(fallback: status) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: presentation.directoryStatus == nil ? "folder" : "exclamationmark.triangle")
                .foregroundStyle(presentation.directoryStatus == nil ? Color.secondary : Color.orange)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SourcePathLabel(url: url)
                if !issues.isEmpty {
                    HoverDetailsButton(accessibilityLabel: "查看来源问题详情，\(statusText)",
                        accessibilityIdentifier: "source-issues-\(url.path)") {
                        Text(statusText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } content: {
                        SourceIssuesContent(sourceURL: url, issues: issues, recoveryPending: recoveryPending,
                            isScanningDirectory: isScanningDirectory)
                    }
                    .font(.caption)
                } else {
                    Text(statusText)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SourceIssuesContent: View {
    let sourceURL: URL
    let issues: [SourceIssueDetail]
    let recoveryPending: Bool
    var isScanningDirectory: Bool = false

    private var presentation: SourceIssuePresentation {
        SourceIssuePresentation(sourceURL: sourceURL, issues: issues, recoveryPending: recoveryPending,
            isScanningDirectory: isScanningDirectory)
    }

    var groups: [(title: String, members: [SourceIssueDetail])] {
        [("目录与连接", SourceIssueKind.sourceAvailability), ("读取与解析", .file), ("导入与提交", .submission)]
            .compactMap { title, kind in
                let members = issues.filter { $0.kind == kind }.sorted {
                    $0.path == $1.path ? $0.id < $1.id : $0.path < $1.path
                }
                return members.isEmpty ? nil : (title, members)
            }
    }

    var body: some View {
        if !issues.isEmpty, issues.allSatisfy({ $0.kind == .sourceAvailability && $0.path == sourceURL.path }) {
            ShortExplanationContent(title: "来源目录不可用", text: "请检查来源磁盘或网络连接。")
                .accessibilityIdentifier("source-issues-content")
        } else { detailedContent }
    }

    private var detailedContent: some View {
        DetailsScrollView(width: 360) {
            VStack(alignment: .leading, spacing: 12) {
                Text(sourceURL.path).font(.headline)
                if let directoryStatus = presentation.directoryStatus {
                    Text(directoryStatus).font(.caption).foregroundStyle(.secondary)
                }
                if presentation.fileProblemCount > 0 {
                    Text("当前未解决 \(presentation.fileProblemCount) 项问题").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.title) { group in
                    issueGroup(group.title, members: group.members)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("source-issues-content")
    }

    private func issueGroup(_ title: String, members: [SourceIssueDetail]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(members) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.path).font(.caption).fontWeight(.medium)
                    Text(issue.summary).font(.caption)
                    if let stage = issue.stage { Text("步骤：\(stage)").font(.caption) }
                    Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
