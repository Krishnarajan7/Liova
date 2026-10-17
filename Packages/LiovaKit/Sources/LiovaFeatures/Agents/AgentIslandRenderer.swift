import LiovaPluginKit
import LiovaUI
import SwiftUI

/// Draws agent activities: the agent's mark and status when closed, and for a
/// permission prompt, the request with Allow / Deny when open.
@MainActor
public final class AgentIslandRenderer: ActivityRenderer {
    private let feature: AgentIslandFeature

    public init(feature: AgentIslandFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(activity.tint == .green ? Color.green : Color.orange)
        )
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        // Static glyphs only: the closed notch never loops an animation (see PERFORMANCE.md).
        let symbol = AgentIslandPolicy.isPrompt(activity.id) ? "hand.raised.fill" : activity.symbol ?? "ellipsis"
        let color: Color = AgentIslandPolicy.isPrompt(activity.id) ? .orange
            : activity.tint == .green ? .green : .white.opacity(0.7)
        return AnyView(
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        )
    }

    public func expandedNeedsFullHeight(for activity: Activity) -> Bool {
        AgentIslandPolicy.isPrompt(activity.id)
    }

    public func expanded(for activity: Activity) -> AnyView? {
        guard let promptID = AgentIslandPolicy.promptID(from: activity.id),
              let prompt = feature.prompt(promptID)
        else { return nil }
        return AnyView(PermissionCard(prompt: prompt, feature: feature))
    }
}

private struct PermissionCard: View {
    let prompt: AgentPermissionPrompt
    let feature: AgentIslandFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let project = prompt.project {
                    Text(project)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Text(prompt.summary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                DecisionButton(title: "Answer in Terminal", style: .quiet) {
                    feature.answer(prompt.id, with: .ask)
                }
                Spacer(minLength: 0)
                DecisionButton(title: "Deny", style: .destructive) {
                    feature.answer(prompt.id, with: .deny)
                }
                DecisionButton(title: "Allow", style: .primary) {
                    feature.answer(prompt.id, with: .allow)
                }
            }
        }
    }

    private var header: String {
        let name = AgentIslandPolicy.displayName(forAgent: prompt.agent)
        return prompt.tool == "Bash" ? "\(name) wants to run a command" : "\(name) wants to use \(prompt.tool)"
    }
}

private struct DecisionButton: View {
    enum Style {
        case primary, destructive, quiet
    }

    let title: String
    let style: Style
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: style == .quiet ? .medium : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, style == .quiet ? 6 : 14)
                .frame(height: 26)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foreground: Color {
        switch style {
        case .primary: .black
        case .destructive: .white
        case .quiet: .white.opacity(isHovered ? 0.9 : 0.55)
        }
    }

    private var background: Color {
        switch style {
        case .primary: .white.opacity(isHovered ? 1 : 0.9)
        case .destructive: .red.opacity(isHovered ? 0.55 : 0.4)
        case .quiet: .clear
        }
    }
}
