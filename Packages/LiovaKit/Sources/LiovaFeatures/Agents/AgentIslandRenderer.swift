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
        if let promptID = AgentIslandPolicy.promptID(from: activity.id) {
            return feature.prompt(promptID).map { AnyView(PermissionCard(prompt: $0, feature: feature)) }
        }
        // A session Liova can take you to gets a card with a way there; any other keeps
        // the standard card.
        guard let session = feature.session(for: activity.id),
              feature.canJump(toAgent: session.agent, sessionID: session.sessionID)
        else { return nil }
        return AnyView(SessionCard(activity: activity, session: session, feature: feature))
    }
}

/// A session's card: what the agent is doing, and a button that goes to its terminal.
private struct SessionCard: View {
    let activity: Activity
    let session: AgentSession
    let feature: AgentIslandFeature
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.symbol ?? "sparkle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(activity.tint.color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(activity.tint.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = activity.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                feature.jumpToTerminal(agent: session.agent, sessionID: session.sessionID)
            } label: {
                Label("Go to it", systemImage: "arrow.up.forward.app.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 1 : 0.85))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(.white.opacity(isHovered ? 0.2 : 0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Bring this session's terminal to the front")
        }
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
                    // Take them there: that's where the agent's own prompt now waits.
                    feature.jumpToTerminal(agent: prompt.agent, sessionID: prompt.sessionID)
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
