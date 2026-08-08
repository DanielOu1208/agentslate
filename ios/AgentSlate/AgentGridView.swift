import AgentSlateClient
import SwiftUI

struct AgentGrid: View {
  let agents: [BridgeAgent]
  let selectedAgentID: String?
  let cell: CGFloat
  let gap: CGFloat
  let select: (BridgeAgent) -> Void
  let tapPlaceholder: () -> Void

  private var columns: [GridItem] {
    Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 4)
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVGrid(columns: columns, spacing: gap) {
        ForEach(agents) { agent in
          AgentKey(agent: agent, selected: agent.id == selectedAgentID) {
            select(agent)
          }
          .frame(width: cell, height: cell)
        }

        ForEach(0..<max(0, 12 - agents.count), id: \.self) { _ in
          EmptyAgentSlot(action: tapPlaceholder)
            .frame(width: cell, height: cell)
        }
      }
      .padding(.vertical, 4)
    }
    .scrollClipDisabled()
    .frame(height: cell * 3 + gap * 2 + 8)
  }
}

private struct EmptyAgentSlot: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Color.clear
        .contentShape(Rectangle())
    }
    .buttonStyle(TactileKeyStyle())
    .accessibilityLabel("Empty agent key")
    .accessibilityHint("Placeholder. No remote command is sent.")
  }
}

private struct AgentKey: View {
  let agent: BridgeAgent
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        ZStack {
          AgentStatusRing(status: agent.status)
            .frame(width: 42, height: 42)

          agentIcon
            .frame(width: 28, height: 28)
        }
        .offset(y: -7)

        VStack(spacing: 0) {
          Spacer(minLength: 0)

          if let folder = agentFolderName(cwd: agent.cwd, workspace: agent.workspace) {
            Text(folder)
              .font(.system(size: 8, weight: .semibold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.65)
              .frame(maxWidth: .infinity)
              .opacity(0.68)
          }
        }
      }
      .foregroundStyle(Palette.buttonIcon)
      .padding(11)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(TactileKeyStyle(dishOffsetY: -7))
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
          .stroke(Palette.blue, lineWidth: 2)
          .shadow(color: Palette.blue.opacity(0.7), radius: 6)
          .allowsHitTesting(false)
      }
    }
    .accessibilityLabel(
      "\(agent.name), \(agentFolderName(cwd: agent.cwd, workspace: agent.workspace) ?? "unknown folder"), \(agent.status.label)\(selected ? ", selected" : "")"
    )
  }

  @ViewBuilder private var agentIcon: some View {
    if let asset = agentIconAssetName(for: agent.kind) {
      Image(asset)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "terminal.fill")
        .resizable()
        .scaledToFit()
    }
  }
}

private struct AgentStatusRing: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let status: AgentStatus

  var body: some View {
    let animates = status == .working && !reduceMotion

    TimelineView(.animation(paused: !animates)) { context in
      ZStack {
        if status != .working {
          Circle()
            .stroke(.white.opacity(0.75), lineWidth: 3)
        }

        ring
          .rotationEffect(animates ? rotation(at: context.date) : .zero)
      }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder private var ring: some View {
    switch status {
    case .working:
      Circle()
        .stroke(
          AngularGradient(
            stops: [
              .init(color: .clear, location: 0),
              .init(color: .clear, location: 0.15),
              .init(color: Palette.blue.opacity(0.10), location: 0.27),
              .init(color: Palette.blue.opacity(0.32), location: 0.70),
              .init(color: Palette.blue.opacity(0.72), location: 0.88),
              .init(color: .clear, location: 1),
            ],
            center: .center
          ),
          lineWidth: 2
        )
    case .blocked:
      Circle()
        .stroke(color, lineWidth: 2)
        .phaseAnimator(reduceMotion ? [false] : [false, true]) { ring, faded in
          ring.opacity(faded ? 0.55 : 1)
        } animation: { _ in
          .easeInOut(duration: 0.8)
        }
    case .done:
      Circle()
        .stroke(color, lineWidth: 2)
    case .idle:
      Circle()
        .stroke(color, lineWidth: 1)
    case .unknown:
      Circle()
        .stroke(
          color,
          style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [1.5, 3])
        )
    }
  }

  private var color: Color {
    switch status {
    case .working: Palette.blue.opacity(0.82)
    case .blocked: .orange
    case .done: Color(red: 0.25, green: 0.70, blue: 0.46)
    case .idle, .unknown: Color(red: 0.64, green: 0.67, blue: 0.72)
    }
  }

  private func rotation(at date: Date) -> Angle {
    let duration = 1.8
    let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
      / duration
    return .degrees(progress * 360)
  }
}

func agentIconAssetName(for kind: String) -> String? {
  switch kind.lowercased() {
  case "pi": "AgentPi"
  case "omp": "AgentOMP"
  case "copilot": "AgentCopilot"
  case "devin": "AgentDevin"
  case "kimi": "AgentKimi"
  case "hermes": "AgentHermes"
  case "qoder", "qodercli": "AgentQoder"
  case "droid": "AgentDroid"
  case "opencode": "AgentOpenCode"
  case "kilo": "AgentKilo"
  case "mastracode": "AgentMastraCode"
  case "claude": "AgentClaude"
  case "codex": "AgentCodex"
  case "cursor": "AgentCursor"
  case "amp": "AgentAmp"
  case "grok": "AgentGrok"
  case "agy", "antigravity": "AgentAntigravity"
  case "kiro": "AgentKiro"
  case "maki": "AgentMaki"
  case "gemini": "AgentGemini"
  case "cline": "AgentCline"
  default: nil
  }
}

func agentFolderName(cwd: String?, workspace: String?) -> String? {
  if let cwd, !cwd.isEmpty {
    let folder = URL(fileURLWithPath: cwd).lastPathComponent
    if !folder.isEmpty { return folder }
  }
  return workspace
}

extension AgentStatus {
  var label: String {
    switch self {
    case .working: "Thinking"
    case .blocked: "Blocked"
    case .done: "Done"
    case .idle: "Idle"
    case .unknown(let value): value.isEmpty ? "Unknown" : value.capitalized
    }
  }
}

func supportsRemoteActions(for agent: BridgeAgent) -> Bool {
  guard agent.status == .blocked else { return false }
  return switch agent.kind {
  case "codex", "claude", "omp", "cursor", "opencode": true
  default: false
  }
}
