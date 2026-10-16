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

struct SourceRowLabel: View {
    let url: URL
    let status: String
    var issues: [SourceIssueDetail] = []
    var recoveryPending: Bool = false

    var statusText: String {
        !issues.isEmpty ? "发现 \(issues.count) 项问题" : (recoveryPending ? "等待确认来源恢复" : status)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SourcePathLabel(url: url)
                if !issues.isEmpty {
                    HoverDetailsButton(accessibilityLabel: "查看来源问题详情，\(issues.count) 项问题",
                        accessibilityIdentifier: "source-issues-\(url.path)") {
                        Text(statusText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } content: {
                        SourceIssuesContent(sourceURL: url, issues: issues, recoveryPending: recoveryPending)
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
        DetailsScrollView(width: 360) {
            VStack(alignment: .leading, spacing: 12) {
                Text(sourceURL.path).font(.headline)
                Text("当前未解决 \(issues.count) 项问题").font(.caption).foregroundStyle(.secondary)
                if recoveryPending { Text("等待确认来源恢复").font(.caption).foregroundStyle(.secondary) }
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
