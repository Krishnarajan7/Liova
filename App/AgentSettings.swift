import LiovaCore
import LiovaFeatures
import SwiftUI

/// The Agents tab: coding agents in the notch, and connecting each one.
struct AgentSettings: View {
    @Bindable var settings: LiovaSettings
    @State private var connections = AgentConnections()

    var body: some View {
        Form {
            Section {
                Toggle("Show coding agents in the notch", isOn: $settings.agentIslandEnabled)
                Toggle("Open the notch when an agent asks for permission", isOn: $settings.agentOpensNotchForApprovals)
                    .disabled(!settings.agentIslandEnabled)
            } footer: {
                Text(
                    "See what your coding agents are doing and approve or deny requests from the notch. "
                        + "If you don't answer, the agent asks in its terminal as usual."
                )
            }
            Section {
                Picker("While music plays, show", selection: $settings.agentsOverMusic) {
                    Text("The agent").tag(true)
                    Text("The music").tag(false)
                }
                .disabled(!settings.agentIslandEnabled)
            } footer: {
                Text(
                    "Permission requests and \"Finished\" always show. Whatever isn't in front is a row "
                        + "beneath it in the open notch: click the row to switch."
                )
            }
            Section {
                ForEach(AgentConnections.agents) { agent in
                    AgentRow(agent: agent, connections: connections)
                }
            } header: {
                Text("Connect your agents")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Connecting adds Liova's hooks to the agent's settings file and keeps a backup. "
                            + "Only event types, the project folder name and a short tool summary are shared, "
                            + "never your prompts."
                    )
                    if !connections.isInApplications {
                        Text(
                            "Move Liova to your Applications folder before connecting, so the connection keeps working."
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { connections.refresh() }
    }
}

private struct AgentRow: View {
    let agent: AgentConnections.Agent
    let connections: AgentConnections

    var body: some View {
        let status = connections.statuses[agent.id] ?? .checking
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                Text(agent.approvals ? "Status and approvals" : "Status only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("Disconnect") { connections.disconnect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case .connectedElsewhere:
                Text("Connected (another copy)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The hooks run a different copy of liova. Update to use this app's.")
                Button("Update") { connections.connect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case .notConnected:
                Button("Connect") { connections.connect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { connections.connect(agent.id) }
            }
        }
    }
}
