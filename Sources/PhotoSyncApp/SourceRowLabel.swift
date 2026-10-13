import SwiftUI

/// One rich line gives the whole path a single head-truncation boundary.
struct SourcePathLabel: View {
    let url: URL

    private var pathText: Text {
        let path = url.path
        let basename = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        let prefix = path == "/" ? "" : String(path.dropLast(basename.count))
        return Text(prefix).font(.caption).foregroundColor(.secondary)
            + Text(basename).font(.body).foregroundColor(.primary)
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
    var detail: String? = nil
    var fileIssueCount: Int = 0

    private var failureCount: String { "读取失败 \(fileIssueCount) 个" }
    private var statusHelp: String {
        ([status] + (fileIssueCount > 0 ? [failureCount] : []) + [detail].compactMap { $0 })
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SourcePathLabel(url: url)
                HStack(spacing: 6) {
                    Text(status).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if fileIssueCount > 0 {
                        Text(failureCount).fixedSize(horizontal: true, vertical: true)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(statusHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
