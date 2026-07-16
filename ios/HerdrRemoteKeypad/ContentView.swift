import HerdrRemoteClient
import SwiftUI

struct ContentView: View {
  @State private var model = AppModel()
  @State private var showingSettings = false
  @State private var placeholderFeedback = 0

  var body: some View {
    GeometryReader { geometry in
      let width = min(geometry.size.width - 36, 444)
      let gap: CGFloat = 12
      let cell = (width - gap * 3) / 4

      ZStack {
        Palette.canvas.ignoresSafeArea()

        VStack(spacing: 0) {
          statusBar
            .padding(.bottom, gap)
          AgentGrid(
            agents: model.displayAgents,
            selectedAgentID: model.selectedAgentID,
            cell: cell,
            gap: gap,
            select: { agent in Task { await model.select(agent) } },
            tapPlaceholder: tapPlaceholder
          )

          Spacer(minLength: gap * 2)

          ControlBank(
            cell: cell,
            gap: gap,
            enabled: model.canSend,
            send: { key in Task { await model.send(key) } },
            tapPlaceholder: tapPlaceholder
          )
        }
        .frame(width: width)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .tint(Palette.blue)
    .sensoryFeedback(.success, trigger: model.successFeedback)
    .sensoryFeedback(.error, trigger: model.errorFeedback)
    .sensoryFeedback(.impact(weight: .medium), trigger: placeholderFeedback)
    .sheet(isPresented: $showingSettings) {
      SettingsView(model: model)
    }
    .task {
      model.start()
      if !model.hasConfiguration { showingSettings = true }
    }
  }

  private func tapPlaceholder() {
    placeholderFeedback += 1
  }

  private var statusBar: some View {
    HStack {
      Circle()
        .fill(connectionColor)
        .frame(width: 10, height: 10)
        .shadow(color: connectionColor.opacity(0.35), radius: 5)
        .accessibilityLabel(model.connectionLabel)

      Spacer()

      Button {
        showingSettings = true
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Palette.graphite)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(RoundControlStyle())
      .accessibilityLabel("Bridge settings")
    }
    .frame(height: 52)
  }

  private var connectionColor: Color {
    if model.connectionState == .connected && model.herdrAvailability == .connected {
      Palette.done
    } else if model.connectionState == .connected {
      Palette.blocked
    } else if model.connectionState != .stopped {
      Palette.blue
    } else {
      Palette.disabled
    }
  }
}

private struct AgentGrid: View {
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

        ForEach(0..<max(0, 8 - agents.count), id: \.self) { _ in
          EmptyAgentSlot(action: tapPlaceholder)
            .frame(width: cell, height: cell)
        }
      }
      .padding(.vertical, 4)
    }
    .scrollClipDisabled()
    .frame(height: cell * 2 + gap + 8)
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
      VStack(spacing: 5) {
        HStack {
          Circle()
            .fill(selected ? .white.opacity(0.9) : agent.status.color)
            .frame(width: 7, height: 7)
          Spacer(minLength: 0)
        }

        Spacer(minLength: 0)

        Text(agent.name)
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.65)

        if let workspace = agent.workspace {
          Text(workspace)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .opacity(0.72)
        }
      }
      .foregroundStyle(selected ? .white : Palette.graphite)
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(TactileKeyStyle(primary: selected))
    .accessibilityLabel(
      "\(agent.name), \(agent.workspace ?? "unknown workspace"), \(agent.status.label)\(selected ? ", selected" : "")"
    )
  }
}

private struct ControlBank: View {
  let cell: CGFloat
  let gap: CGFloat
  let enabled: Bool
  let send: (RemoteKey) -> Void
  let tapPlaceholder: () -> Void

  private var columns: [GridItem] {
    Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 2)
  }

  var body: some View {
    VStack(spacing: gap) {
      HStack(spacing: gap) {
        DPad(cell: cell, enabled: enabled, send: send)
          .frame(width: cell * 2 + gap, height: cell * 2 + gap)

        LazyVGrid(columns: columns, spacing: gap) {
          PlaceholderKey(symbol: "xmark", accessibilityName: "Deny", action: tapPlaceholder)
            .frame(width: cell, height: cell)
          PlaceholderKey(
            symbol: "checkmark",
            accessibilityName: "Accept",
            action: tapPlaceholder
          )
          .frame(width: cell, height: cell)
          RemoteKeyButton(key: .enter, enabled: enabled, send: send)
          RemoteKeyButton(key: .tab, enabled: enabled, send: send)
        }
        .frame(width: cell * 2 + gap)
      }

      PlaceholderKey(symbol: "mic", accessibilityName: "Voice", action: tapPlaceholder)
        .frame(width: cell * 2 + gap, height: cell)
    }
  }
}

private struct DPad: View {
  let cell: CGFloat
  let enabled: Bool
  let send: (RemoteKey) -> Void

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height

      ZStack {
        DPadShape(armWidth: cell, cornerRadius: 14)
          .fill(
            LinearGradient(
              colors: [.white, Palette.keyFace],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .background {
            DPadShape(armWidth: cell, cornerRadius: 14)
              .fill(Palette.keyLip)
              .offset(y: 4)
          }
          .overlay {
            DPadShape(armWidth: cell, cornerRadius: 14)
              .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
          }
          .shadow(color: Palette.shadow.opacity(0.1), radius: 3, y: 4)

        DPadDirection(key: .arrowUp, enabled: enabled, send: send)
          .frame(width: cell, height: cell)
          .position(x: width / 2, y: cell / 2)
        DPadDirection(key: .arrowLeft, enabled: enabled, send: send)
          .frame(width: cell, height: cell)
          .position(x: cell / 2, y: height / 2)
        DPadDirection(key: .arrowRight, enabled: enabled, send: send)
          .frame(width: cell, height: cell)
          .position(x: width - cell / 2, y: height / 2)
        DPadDirection(key: .arrowDown, enabled: enabled, send: send)
          .frame(width: cell, height: cell)
          .position(x: width / 2, y: height - cell / 2)
      }
    }
    .opacity(enabled ? 1 : 0.5)
    .animation(.easeOut(duration: 0.18), value: enabled)
  }
}

private struct DPadShape: Shape {
  let armWidth: CGFloat
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let left = (rect.width - armWidth) / 2
    let right = (rect.width + armWidth) / 2
    let top = (rect.height - armWidth) / 2
    let bottom = (rect.height + armWidth) / 2
    let radius = min(cornerRadius, left / 2, top / 2, armWidth / 4)
    var path = Path()
    path.move(to: CGPoint(x: left + radius, y: rect.minY))
    path.addLine(to: CGPoint(x: right - radius, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: right, y: rect.minY + radius),
      control: CGPoint(x: right, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: right, y: top - radius))
    path.addQuadCurve(
      to: CGPoint(x: right + radius, y: top),
      control: CGPoint(x: right, y: top)
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: top + radius),
      control: CGPoint(x: rect.maxX, y: top)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - radius, y: bottom),
      control: CGPoint(x: rect.maxX, y: bottom)
    )
    path.addLine(to: CGPoint(x: right + radius, y: bottom))
    path.addQuadCurve(
      to: CGPoint(x: right, y: bottom + radius),
      control: CGPoint(x: right, y: bottom)
    )
    path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: right - radius, y: rect.maxY),
      control: CGPoint(x: right, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: left, y: rect.maxY - radius),
      control: CGPoint(x: left, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: left, y: bottom + radius))
    path.addQuadCurve(
      to: CGPoint(x: left - radius, y: bottom),
      control: CGPoint(x: left, y: bottom)
    )
    path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: bottom - radius),
      control: CGPoint(x: rect.minX, y: bottom)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: top),
      control: CGPoint(x: rect.minX, y: top)
    )
    path.addLine(to: CGPoint(x: left - radius, y: top))
    path.addQuadCurve(
      to: CGPoint(x: left, y: top - radius),
      control: CGPoint(x: left, y: top)
    )
    path.addLine(to: CGPoint(x: left, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: left + radius, y: rect.minY),
      control: CGPoint(x: left, y: rect.minY)
    )
    path.closeSubpath()
    return path
  }
}

private struct DPadDirection: View {
  let key: RemoteKey
  let enabled: Bool
  let send: (RemoteKey) -> Void

  var body: some View {
    Button {
      send(key)
    } label: {
      Image(systemName: key.symbol)
        .font(.system(size: 25, weight: .semibold))
        .foregroundStyle(Palette.graphite)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(DPadDirectionStyle())
    .disabled(!enabled)
    .accessibilityLabel(key.accessibilityName)
  }
}

private struct DPadDirectionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      KeyDish()
        .padding(8)
      configuration.label
    }
    .offset(y: configuration.isPressed ? 2 : 0)
    .scaleEffect(configuration.isPressed ? 0.94 : 1)
    .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
  }
}

private struct RemoteKeyButton: View {
  let key: RemoteKey
  let enabled: Bool
  let send: (RemoteKey) -> Void

  var body: some View {
    Button {
      send(key)
    } label: {
      VStack(spacing: 7) {
        Image(systemName: key.symbol)
          .font(.system(size: 25, weight: .semibold))
        Text(key.caption ?? "")
          .font(.system(size: 9, weight: .black, design: .rounded))
          .tracking(0.8)
      }
      .foregroundStyle(Palette.graphite)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(TactileKeyStyle())
    .disabled(!enabled)
    .aspectRatio(1, contentMode: .fit)
    .opacity(enabled ? 1 : 0.5)
    .animation(.easeOut(duration: 0.18), value: enabled)
    .accessibilityLabel(key.accessibilityName)
  }
}

private struct PlaceholderKey: View {
  let symbol: String
  let accessibilityName: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(Palette.graphite)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(TactileKeyStyle())
    .accessibilityLabel(accessibilityName)
    .accessibilityHint("Placeholder. No remote command is sent.")
  }
}

private struct TactileKeyStyle: ButtonStyle {
  var primary = false

  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 21, style: .continuous)
        .fill(primary ? Palette.blueLip : Palette.keyLip)
        .offset(y: 4)

      ZStack {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
          .fill(
            LinearGradient(
              colors: primary
                ? [Palette.blueHighlight, Palette.blue]
                : [.white, Palette.keyFace],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        RoundedRectangle(cornerRadius: 21, style: .continuous)
          .stroke(primary ? .white.opacity(0.28) : .white.opacity(0.95), lineWidth: 1)
        KeyDish(primary: primary)
          .padding(18)
        configuration.label
      }
      .offset(y: configuration.isPressed ? 3 : 0)
    }
    .shadow(
      color: Palette.shadow.opacity(configuration.isPressed ? 0.05 : 0.1),
      radius: configuration.isPressed ? 1 : 3,
      y: configuration.isPressed ? 2 : 4
    )
    .scaleEffect(configuration.isPressed ? 0.99 : 1)
    .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
  }
}

private struct KeyDish: View {
  var primary = false

  var body: some View {
    Circle()
      .fill(
        RadialGradient(
          stops: [
            .init(color: .white.opacity(primary ? 0.09 : 0.28), location: 0),
            .init(color: .clear, location: 0.58),
            .init(
              color: (primary ? Palette.blueLip : Palette.shadow).opacity(
                primary ? 0.16 : 0.1),
              location: 1
            ),
          ],
          center: .center,
          startRadius: 1,
          endRadius: 50
        )
      )
      .overlay {
        Circle()
          .stroke(
            LinearGradient(
              colors: [
                (primary ? Palette.blueLip : Palette.shadow).opacity(primary ? 0.16 : 0.08),
                .white.opacity(primary ? 0.1 : 0.45),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      }
  }
}

private struct RoundControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      Circle()
        .fill(Palette.keyLip)
        .offset(y: 3)
      Circle()
        .fill(.white)
        .overlay(Circle().stroke(.white, lineWidth: 1))
        .offset(y: configuration.isPressed ? 2 : 0)
      configuration.label
        .offset(y: configuration.isPressed ? 2 : 0)
    }
    .shadow(color: Palette.shadow.opacity(0.08), radius: 3, y: 3)
  }
}

private struct SettingsView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var host: String
  @State private var token: String

  init(model: AppModel) {
    self.model = model
    _host = State(initialValue: model.configuredHost)
    _token = State(initialValue: model.configuredToken)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Bridge") {
          TextField("Tailscale host", text: $host)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          SecureField("64-character token", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.oneTimeCode)
            .font(.system(.body, design: .monospaced))
        }

        Section {
          Text(
            "The app connects to port 8765. The token stays in this device's Keychain and is never logged."
          )
          .font(.footnote)
          .foregroundStyle(Palette.secondaryText)
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(Palette.blocked)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Palette.canvas)
      .navigationTitle("Bridge setup")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.hasConfiguration {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save & Connect") {
            if model.configure(host: host, token: token) { dismiss() }
          }
          .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty)
        }
      }
    }
    .interactiveDismissDisabled(!model.hasConfiguration)
  }
}

private enum Palette {
  static let canvas = Color(red: 0.956, green: 0.965, blue: 0.976)
  static let well = Color(red: 0.902, green: 0.922, blue: 0.945)
  static let keyFace = Color(red: 0.918, green: 0.936, blue: 0.955)
  static let keyLip = Color(red: 0.78, green: 0.81, blue: 0.85)
  static let line = Color(red: 0.817, green: 0.842, blue: 0.872)
  static let graphite = Color(red: 0.055, green: 0.067, blue: 0.086)
  static let secondaryText = Color(red: 0.32, green: 0.35, blue: 0.4)
  static let shadow = Color(red: 0.15, green: 0.19, blue: 0.24)
  static let blue = Color(red: 0.045, green: 0.365, blue: 1)
  static let blueHighlight = Color(red: 0.24, green: 0.51, blue: 1)
  static let blueLip = Color(red: 0.025, green: 0.24, blue: 0.72)
  static let blocked = Color(red: 0.89, green: 0.22, blue: 0.20)
  static let done = Color(red: 0.10, green: 0.60, blue: 0.34)
  static let disabled = Color(red: 0.55, green: 0.58, blue: 0.63)
}

extension AgentStatus {
  fileprivate var label: String {
    switch self {
    case .working: "Working"
    case .blocked: "Blocked"
    case .done: "Done"
    case .idle: "Idle"
    case .unknown(let value): value.isEmpty ? "Unknown" : value.capitalized
    }
  }

  fileprivate var color: Color {
    switch self {
    case .working: Palette.blue
    case .blocked: Palette.blocked
    case .done: Palette.done
    case .idle, .unknown: Palette.disabled
    }
  }
}

extension RemoteKey {
  fileprivate var symbol: String {
    switch self {
    case .arrowUp: "arrow.up"
    case .arrowDown: "arrow.down"
    case .arrowLeft: "arrow.left"
    case .arrowRight: "arrow.right"
    case .enter: "arrow.turn.down.left"
    case .escape: "escape"
    case .tab: "arrow.right.to.line"
    case .space: "space"
    }
  }

  fileprivate var caption: String? {
    switch self {
    case .enter: "ENTER"
    case .tab: "TAB"
    case .escape, .space, .arrowUp, .arrowDown, .arrowLeft, .arrowRight: nil
    }
  }

  fileprivate var accessibilityName: String {
    switch self {
    case .arrowUp: "Up arrow"
    case .arrowDown: "Down arrow"
    case .arrowLeft: "Left arrow"
    case .arrowRight: "Right arrow"
    case .enter: "Enter"
    case .escape: "Escape"
    case .tab: "Tab"
    case .space: "Space"
    }
  }
}
