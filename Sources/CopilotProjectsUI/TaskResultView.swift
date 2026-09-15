import SwiftUI
import CopilotProjectsProtocol

public struct TaskResultView: View {
    public let result: RemoteTaskResult

    public init(result: RemoteTaskResult) {
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Latest task result", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Text(result.status == "stopped" ? "Stopped" : result.status == "blocked" ? "Blocked" : "Finished")
                    .font(.caption.weight(.semibold))
            }
            Text(result.capturedAt, style: .time).font(.caption).foregroundStyle(.secondary)
            if let summary = result.summary, !summary.isEmpty {
                Text(summary).textSelection(.enabled)
            }
            if let branch = result.branch {
                Label(branch, systemImage: "arrow.triangle.branch").font(.caption)
            }
            if let error = result.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if !result.checks.isEmpty {
                DisclosureGroup("Executed checks (exit status)") {
                    ForEach(result.checks) { check in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(check.title).font(.caption.monospaced())
                                Spacer()
                                Text(check.outcome).font(.caption)
                            }
                            if let directory = check.workingDirectory {
                                Text(directory).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let diff = result.diff {
                DisclosureGroup("\(diff.title) (\(diff.changes.count) files)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Captured when the task stopped running; this is not a per-turn diff.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let reason = diff.unavailableReason {
                            Text("Session capture unavailable: \(reason)").font(.caption)
                        }
                        if diff.truncated {
                            Text("Only part of this diff is shown. Inspect the full working tree in the terminal.")
                                .font(.caption)
                        }
                        ForEach(diff.changes) { change in
                            DisclosureGroup(change.path) {
                                if change.truncated {
                                    Text("File diff truncated").font(.caption)
                                }
                                ScrollView([.horizontal, .vertical]) {
                                    Text(change.diff).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 320)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            ForEach(result.pullRequests, id: \.self) { link in
                if let url = URL(string: link), url.scheme == "https", url.host == "github.com" {
                    Link("Pull request reported by tool", destination: url).font(.callout)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
