import AgentSlateClient
import SwiftUI

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AppModel()
  @State private var showingSettings = false
  @State private var agentSelectionFeedback = 0
  @State private var placeholderFeedback = 0
  @State private var armedVoiceAction = VoiceReleaseAction.send
  @State private var voiceSelectionFeedback = 0

  var body: some View {
    GeometryReader { geometry in
      let width = min(geometry.size.width - 36, 444)
      let gap: CGFloat = 12
      let cell = (width - gap * 3) / 4
      let targets = VoiceTargetLayout.frames(
        in: geometry.size, contentWidth: width, gap: gap, targetHeight: cell)
      let talking = model.voiceState.isTalking

      ZStack {
        Group {
          Palette.canvas.ignoresSafeArea()

          VStack(spacing: 0) {
            statusBar
              .padding(.bottom, gap)
            AgentGrid(
              agents: model.displayAgents,
              selectedAgentID: model.selectedAgentID,
              cell: cell,
              gap: gap,
              select: { agent in
                agentSelectionFeedback += 1
                Task { await model.select(agent) }
              },
              tapPlaceholder: tapPlaceholder
            )

            Spacer(minLength: gap * 2)

            ControlBank(
              cell: cell,
              gap: gap,
              enabled: model.canSend,
              actionEnabled: model.canSendAction,
              voiceState: model.voiceState,
              partialTranscript: model.partialTranscript,
              send: { key in Task { await model.send(key) } },
              sendAction: { action in Task { await model.send(action) } },
              retryVoice: { Task { await model.prepareVoice() } }
            )
          }
          .frame(width: width)
          .padding(.top, 8)
          .padding(.bottom, 20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .blur(radius: talking ? 5 : 0)
        .allowsHitTesting(!talking)
        .accessibilityHidden(talking)

        if talking {
          Color.black.opacity(0.40)
            .ignoresSafeArea()
            .allowsHitTesting(false)

          TalkingPresentation(
            state: model.voiceState,
            transcript: model.partialTranscript,
            action: armedVoiceAction,
            targets: targets,
            contentWidth: width,
            gap: gap
          )
          .allowsHitTesting(false)
        }

        VStack {
          Spacer()
          VoiceKey(
            enabled: model.canSend
              && (model.voiceState == .ready || model.voiceState.isTalking),
            isListening: talking,
            cancelTarget: targets.cancel,
            editTarget: targets.edit,
            beginVoice: {
              armedVoiceAction = .send
              model.beginVoice()
            },
            releaseVoice: { action in
              Task {
                await model.finishVoice(action)
                armedVoiceAction = .send
              }
            },
            cancelVoice: { Task { await model.cancelVoice() } },
            armVoice: armVoice
          )
          .frame(width: cell * 2 + gap, height: cell)
          .padding(.bottom, VoiceTargetLayout.bottomPadding)
        }
      }
      .coordinateSpace(name: VoiceTargetLayout.coordinateSpace)
    }
    .tint(Palette.blue)
    .sensoryFeedback(.success, trigger: model.successFeedback)
    .sensoryFeedback(.error, trigger: model.errorFeedback)
    .sensoryFeedback(.selection, trigger: agentSelectionFeedback)
    .sensoryFeedback(.impact(weight: .medium), trigger: placeholderFeedback)
    .sensoryFeedback(.selection, trigger: voiceSelectionFeedback)
    .sheet(isPresented: $showingSettings) {
      SettingsView(model: model)
    }
    .sheet(
      item: Binding(
        get: { model.voiceDraft },
        set: { if $0 == nil { model.discardVoiceDraft() } }
      )
    ) { draft in
      VoiceReviewView(model: model, draft: draft)
        .presentationDetents([.large])
    }
    .task {
      model.start()
      if model.hasConfiguration {
        await model.prepareVoice()
      } else {
        showingSettings = true
      }
    }
    .onChange(of: showingSettings) { _, isShowing in
      guard !isShowing, model.hasConfiguration || model.isDemoMode else { return }
      Task { await model.prepareVoice() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        guard model.hasConfiguration || model.isDemoMode else { return }
        Task { await model.prepareVoice() }
      } else {
        Task { await model.cancelVoice() }
      }
    }
    .onChange(of: model.canSend) { _, canSend in
      if !canSend { Task { await model.cancelVoice() } }
    }
  }

  private func tapPlaceholder() {
    placeholderFeedback += 1
  }

  private func armVoice(_ action: VoiceReleaseAction) {
    guard action != armedVoiceAction else { return }
    armedVoiceAction = action
    voiceSelectionFeedback += 1
  }

  private var statusBar: some View {
    HStack {
      Circle()
        .fill(connectionColor)
        .frame(width: 10, height: 10)
        .shadow(color: connectionColor.opacity(0.35), radius: 5)
        .accessibilityLabel(model.connectionLabel)

      sessionControl

      Spacer()

      if model.isDemoMode {
        Text("OFFLINE DEMO")
          .font(.system(size: 10, weight: .black, design: .rounded))
          .tracking(0.7)
          .foregroundStyle(Palette.blue)
          .accessibilityLabel("Offline Demo Mode")
      }

      Button {
        showingSettings = true
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Palette.buttonIcon)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(RoundControlStyle())
      .accessibilityLabel("Bridge settings")
    }
    .frame(height: 52)
  }

  @ViewBuilder private var sessionControl: some View {
    if model.sessions.count > 1 {
      Menu {
        ForEach(model.sessions) { session in
          Button {
            model.select(session)
          } label: {
            if session.name == model.selectedSessionName {
              Label(session.name, systemImage: "checkmark")
            } else {
              Text(session.name)
            }
          }
        }
      } label: {
        sessionLabel(showsChevron: true)
      }
      .accessibilityLabel("Herdr session, \(model.selectedSessionName ?? "none")")
      .accessibilityHint("Switch Herdr session")
    } else {
      sessionLabel(showsChevron: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Herdr session, \(model.selectedSessionName ?? "none")")
    }
  }

  private func sessionLabel(showsChevron: Bool) -> some View {
    HStack(spacing: 7) {
      Image("HerdrLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

      VStack(alignment: .leading, spacing: 0) {
        Text("herdr")
          .font(.system(size: 16, weight: .bold, design: .rounded))
        Text(model.selectedSessionName ?? "No session")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(Palette.secondaryText)
          .lineLimit(1)
      }
      .foregroundStyle(Palette.buttonIcon)

      if showsChevron {
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Palette.secondaryText)
      }
    }
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

private struct ControlBank: View {
  let cell: CGFloat
  let gap: CGFloat
  let enabled: Bool
  let actionEnabled: Bool
  let voiceState: VoiceState
  let partialTranscript: String
  let send: (RemoteKey) -> Void
  let sendAction: (RemoteAction) -> Void
  let retryVoice: () -> Void

  private var columns: [GridItem] {
    Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 2)
  }

  var body: some View {
    VStack(spacing: gap) {
      if showsVoiceStatus {
        voiceStatusLine
      }

      HStack(spacing: gap) {
        DPad(cell: cell, enabled: enabled, send: send)
          .frame(width: cell * 2 + gap, height: cell * 2 + gap)

        LazyVGrid(columns: columns, spacing: gap) {
          RemoteActionButton(action: .deny, enabled: actionEnabled, send: sendAction)
            .frame(width: cell, height: cell)
          RemoteActionButton(action: .accept, enabled: actionEnabled, send: sendAction)
            .frame(width: cell, height: cell)
          RemoteKeyButton(key: .escape, enabled: enabled, send: send)
          RemoteKeyButton(key: .shiftTab, enabled: enabled, send: send)
          RemoteKeyButton(key: .enter, enabled: enabled, send: send)
          RemoteKeyButton(key: .tab, enabled: enabled, send: send)
        }
        .frame(width: cell * 2 + gap)
      }

      Color.clear
        .accessibilityHidden(true)
      .frame(width: cell * 2 + gap, height: cell)
    }
  }

  private var showsVoiceStatus: Bool {
    switch voiceState {
    case .preparing, .finalizing, .failed:
      true
    case .starting, .listening:
      false
    case .notPrepared, .ready:
      !partialTranscript.isEmpty
    }
  }

  @ViewBuilder
  private var voiceStatusLine: some View {
    Group {
      switch voiceState {
      case .preparing:
        Text("Preparing voice…")
          .foregroundStyle(Palette.secondaryText)
          .accessibilityLabel("Preparing voice")
      case .starting:
        Text("Starting microphone…")
          .foregroundStyle(Palette.secondaryText)
          .accessibilityLabel("Starting microphone")
      case .listening:
        Text(partialTranscript.isEmpty ? "Listening…" : partialTranscript)
          .foregroundStyle(Palette.secondaryText)
          .accessibilityLabel(partialTranscript.isEmpty ? "Listening" : partialTranscript)
      case .finalizing:
        Text("Finishing dictation…")
          .foregroundStyle(Palette.secondaryText)
          .accessibilityLabel("Finishing dictation")
      case .failed(let message):
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(message)
              .foregroundStyle(Palette.blocked)
            if !partialTranscript.isEmpty {
              Text(partialTranscript)
                .foregroundStyle(Palette.secondaryText)
            }
          }
          Spacer(minLength: 0)
          Button("Retry", action: retryVoice)
            .buttonStyle(.borderless)
        }
      case .notPrepared, .ready:
        if !partialTranscript.isEmpty {
          Text(partialTranscript)
            .foregroundStyle(Palette.secondaryText)
        }
      }
    }
    .font(.system(size: 13, weight: .medium, design: .rounded))
    .lineLimit(2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct VoiceKey: View {
  let enabled: Bool
  let isListening: Bool
  let cancelTarget: CGRect
  let editTarget: CGRect
  let beginVoice: () -> Void
  let releaseVoice: (VoiceReleaseAction) -> Void
  let cancelVoice: () -> Void
  let armVoice: (VoiceReleaseAction) -> Void

  @GestureState private var isPressed = false
  @State private var isHolding = false

  var body: some View {
    Image(systemName: isListening ? "mic.fill" : "mic")
      .font(.system(size: 30, weight: .medium))
      .foregroundStyle(isListening ? Palette.blue : Palette.buttonIcon)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .opacity(enabled ? 1 : 0.5)
      .animation(.easeOut(duration: 0.18), value: enabled)
      .animation(.easeOut(duration: 0.12), value: isListening)
      .background {
        TactileKeyChrome(isPressed: isPressed || isListening, primary: isListening)
      }
      .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
      .gesture(
        DragGesture(
          minimumDistance: 0,
          coordinateSpace: .named(VoiceTargetLayout.coordinateSpace)
        )
          .updating($isPressed) { _, pressed, _ in
            pressed = true
          }
          .onChanged { value in
            guard isHolding else { return }
            armVoice(
              .classify(
                value.location,
                cancelTarget: cancelTarget,
                editTarget: editTarget
              ))
          }
          .onEnded { value in
            guard isHolding else { return }
            isHolding = false
            guard enabled else {
              cancelVoice()
              return
            }
            releaseVoice(
              .classify(
                value.location,
                cancelTarget: cancelTarget,
                editTarget: editTarget
              ))
          }
      )
      .onChange(of: isPressed) { wasPressed, isPressed in
        if isPressed {
          guard enabled, !isHolding else { return }
          isHolding = true
          beginVoice()
        } else if wasPressed, isHolding {
          isHolding = false
          cancelVoice()
        }
      }
      .disabled(!enabled && !isListening)
      .accessibilityLabel("Voice")
      .accessibilityHint(
        isListening
          ? "Activate to send, or use the Edit dictation or Cancel dictation actions."
          : "Hold to speak and release to send. Drag to a visible Edit or Cancel target before releasing. With VoiceOver, activate once to start."
      )
      .accessibilityAddTraits([.isButton, .startsMediaSession])
      .accessibilityAction(.default) {
        guard enabled || isListening else { return }
        if isListening {
          enabled ? releaseVoice(.send) : cancelVoice()
        } else {
          beginVoice()
        }
      }
      .accessibilityActions {
        if isListening {
          Button("Edit dictation") { releaseVoice(.edit) }
          Button("Cancel dictation", action: cancelVoice)
        }
      }
  }
}

private extension VoiceState {
  var isTalking: Bool {
    self == .starting || self == .listening
  }
}

struct VoiceTargetFrames: Equatable {
  let cancel: CGRect
  let edit: CGRect
}

enum VoiceTargetLayout {
  static let coordinateSpace = "voiceInteraction"
  static let bottomPadding: CGFloat = 20

  static func frames(
    in size: CGSize,
    contentWidth: CGFloat,
    gap: CGFloat,
    targetHeight: CGFloat
  ) -> VoiceTargetFrames {
    let width = (contentWidth - gap) / 2
    let left = (size.width - contentWidth) / 2
    let top = size.height - bottomPadding - targetHeight * 2 - gap
    return VoiceTargetFrames(
      cancel: CGRect(x: left, y: top, width: width, height: targetHeight),
      edit: CGRect(x: left + width + gap, y: top, width: width, height: targetHeight)
    )
  }
}

private struct TalkingPresentation: View {
  let state: VoiceState
  let transcript: String
  let action: VoiceReleaseAction
  let targets: VoiceTargetFrames
  let contentWidth: CGFloat
  let gap: CGFloat

  var body: some View {
    GeometryReader { geometry in
      let transcriptHeight = min(
        max(120, geometry.size.height * 0.42),
        max(0, targets.cancel.minY - gap)
      )

      ZStack {
        VoiceReleaseTarget(action: .cancel, armed: action == .cancel)
          .frame(width: targets.cancel.width, height: targets.cancel.height)
          .position(x: targets.cancel.midX, y: targets.cancel.midY)

        VoiceReleaseTarget(action: .edit, armed: action == .edit)
          .frame(width: targets.edit.width, height: targets.edit.height)
          .position(x: targets.edit.midX, y: targets.edit.midY)

        VoiceTranscript(
          text: displayedTranscript
        )
        .frame(width: contentWidth, height: transcriptHeight)
        .position(
          x: geometry.size.width / 2,
          y: targets.cancel.minY - transcriptHeight / 2 - gap
        )
      }
    }
  }

  private var displayedTranscript: String {
    if state == .starting { return "Starting microphone…" }
    return transcript.isEmpty ? "Listening…" : transcript
  }
}

private struct VoiceReleaseTarget: View {
  let action: VoiceReleaseAction
  let armed: Bool

  var body: some View {
    ZStack {
      TactileKeyChrome(isPressed: armed, showsDish: false)
        .colorMultiply(action == .cancel ? Palette.blocked : .white)

      VStack(spacing: 7) {
        Image(systemName: action == .cancel ? "xmark" : "pencil")
          .font(.system(size: 28, weight: .semibold))
        Text(action == .cancel ? "Cancel" : "Edit")
          .font(.headline)
      }
      .foregroundStyle(foregroundColor)
    }
    .animation(.easeOut(duration: 0.12), value: armed)
    .accessibilityHidden(true)
  }

  private var color: Color {
    action == .cancel ? Palette.blocked : Palette.blueHighlight
  }

  private var foregroundColor: Color {
    if action == .cancel { return .white }
    return armed ? color : Palette.buttonIcon
  }
}

private struct VoiceTranscript: View {
  let text: String

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(text)
          .font(.title2)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 12)
        Color.clear.frame(height: 1).id("transcriptEnd")
      }
      .scrollIndicators(.hidden)
      .onChange(of: text) { _, _ in
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo("transcriptEnd", anchor: .bottom)
        }
      }
    }
    .accessibilityLabel(text)
  }
}

/// Shared tactile chrome for keys that are not Button-based (hold-to-talk).
private struct TactileKeyChrome: View {
  var isPressed: Bool
  var primary = false
  var showsDish = true

  var body: some View {
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
        if showsDish {
          KeyDish(primary: primary)
            .frame(width: keyDishDiameter, height: keyDishDiameter)
        }
      }
      .offset(y: isPressed ? 3 : 0)
    }
    .shadow(
      color: Palette.shadow.opacity(isPressed ? 0.05 : 0.1),
      radius: isPressed ? 1 : 3,
      y: isPressed ? 2 : 4
    )
    .scaleEffect(isPressed ? 0.99 : 1)
    .animation(.easeOut(duration: 0.09), value: isPressed)
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
        .foregroundStyle(Palette.buttonIcon)
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
        .frame(width: keyDishDiameter, height: keyDishDiameter)
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
      .foregroundStyle(Palette.buttonIcon)
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

private struct RemoteActionButton: View {
  let action: RemoteAction
  let enabled: Bool
  let send: (RemoteAction) -> Void

  var body: some View {
    Button {
      if enabled { send(action) }
    } label: {
      Image(systemName: action == .accept ? "checkmark" : "xmark")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(Palette.buttonIcon)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(TactileKeyStyle())
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
    .animation(.easeOut(duration: 0.18), value: enabled)
    .accessibilityLabel(action == .accept ? "Accept" : "Deny")
    .accessibilityHint(
      enabled
        ? "Sends the selected agent's default shortcut."
        : "No approval request is currently available."
    )
  }
}

private struct TactileKeyStyle: ButtonStyle {
  var primary = false
  var dishOffsetY: CGFloat = 0

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
          .frame(width: keyDishDiameter, height: keyDishDiameter)
          .offset(y: dishOffsetY)
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

private let keyDishDiameter: CGFloat = 48

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

private struct VoiceReviewView: View {
  let model: AppModel
  let draft: VoiceDraft

  @State private var text: String
  @State private var selection: TextSelection?
  @State private var sendError: String?
  @State private var isSending = false
  @FocusState private var editorFocused: Bool

  init(model: AppModel, draft: VoiceDraft) {
    self.model = model
    self.draft = draft
    _text = State(initialValue: draft.text)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Agent", value: draft.agentName)
        LabeledContent("Session", value: draft.session)

        TextEditor(text: $text, selection: $selection)
          .focused($editorFocused)
          .font(.body)
          .padding(8)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background, in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(Palette.line, lineWidth: 1)
          }
          .onChange(of: text) { _, _ in sendError = nil }

        if let message = validationMessage {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Palette.blocked)
        }
      }
      .padding()
      .background(Palette.canvas)
      .navigationTitle("Review dictation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { model.discardVoiceDraft() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            isSending = true
            sendError = nil
            Task {
              let sent = await model.sendVoiceDraft(draft, text: text)
              isSending = false
              if sent {
                model.discardVoiceDraft()
              } else {
                sendError = model.errorMessage ?? "The prompt could not be sent. Try again."
              }
            }
          }
          .disabled(!canSend)
        }
      }
      .task {
        selection = TextSelection(insertionPoint: text.endIndex)
        editorFocused = true
      }
    }
  }

  private var validation: VoiceTextValidation {
    validateVoiceDraftText(text)
  }

  private var targetAvailable: Bool {
    draft.matches(
      agentID: model.selectedAgentID,
      session: model.selectedSessionName,
      available: model.canSend
    )
  }

  private var canSend: Bool {
    validation.isValid && targetAvailable && !isSending
  }

  private var validationMessage: String? {
    if let sendError { return sendError }
    switch validation.issue {
    case .blank:
      return "Enter text before sending."
    case .controlCharacters:
      return "Remove tabs or other control characters before sending."
    case .tooLarge:
      return "\(validation.byteCount) of 8,192 UTF-8 bytes. Shorten the prompt to send it."
    case nil:
      if !targetAvailable {
        return "Reconnect and reselect \(draft.agentName) in \(draft.session) to send this draft."
      }
      return nil
    }
  }
}

private struct SettingsView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var host: String
  @State private var code = ""
  @State private var showingForgetConfirmation = false
  @State private var notice: SettingsNotice?

  init(model: AppModel) {
    self.model = model
    _host = State(initialValue: model.configuredHost)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Setup") {
          if model.hasConfiguration {
            Text("Forget the current bridge before pairing with another Mac.")
              .foregroundStyle(Palette.secondaryText)
          } else {
            TextField("Tailscale host", text: $host)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
            TextField("6-digit pairing code", text: $code)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .textContentType(.oneTimeCode)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
              .onChange(of: code) { _, value in
                code = String(
                  decoding: value.utf8.filter { (48...57).contains($0) }.prefix(6),
                  as: UTF8.self
                )
              }

            Button {
              Task {
                if await model.pair(host: host, code: code) {
                  dismiss()
                }
              }
            } label: {
              if model.isPairing {
                HStack {
                  ProgressView()
                  Text("Pairing…")
                }
              } else {
                Text("Pair & Connect")
              }
            }
            .disabled(
              model.isPairing
                || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || code.count != 6
            )
          }
        }

        if !model.hasConfiguration {
          Section {
            Text(
              "On your Mac, run “agentslate pair”, then enter the code shown. AgentSlate connects to port 8765 and keeps the resulting device credential in Keychain."
            )
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
          }
        }

        Section("Offline Preview") {
          Button {
            Task {
              await model.activateDemoMode()
              dismiss()
            }
          } label: {
            Label(
              model.isDemoMode ? "Restart Offline Demo" : "Start Offline Demo",
              systemImage: "iphone.slash"
            )
          }
          Text("Uses fixed fake agents and never contacts a bridge.")
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
        }

        Section("Help & Legal") {
          Link(destination: URL(string: "https://danielou1208.github.io/agentslate/support/")!) {
            Label("Support", systemImage: "questionmark.circle")
          }
          Link(destination: URL(string: "https://danielou1208.github.io/agentslate/privacy/")!) {
            Label("Privacy", systemImage: "hand.raised")
          }
          NavigationLink {
            AcknowledgementsView()
          } label: {
            Label("Acknowledgements", systemImage: "doc.text")
          }
        }

        if model.hasConfiguration {
          Section {
            Button("Forget Bridge", role: .destructive) {
              showingForgetConfirmation = true
            }
          } footer: {
            Text(
              "When connected, AgentSlate also revokes this iPhone on the Mac. If offline, remove the remaining Mac record with “agentslate devices revoke DEVICE_ID”."
            )
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(Palette.blocked)
          }
        }

        Section {
          LabeledContent("Version", value: appVersion)
          Text("Remote control for Herdr.")
            .foregroundStyle(Palette.secondaryText)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Palette.canvas)
      .navigationTitle("AgentSlate")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.hasConfiguration || model.isDemoMode {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
    }
    .interactiveDismissDisabled(!model.hasConfiguration && !model.isDemoMode)
    .confirmationDialog(
      "Forget this bridge?",
      isPresented: $showingForgetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Forget Bridge", role: .destructive) {
        Task {
          let result = await model.forgetBridge()
          notice =
            switch result {
            case .revoked:
              SettingsNotice(
                title: "Bridge Forgotten",
                message: "This iPhone was revoked on the Mac and its local credential was removed."
              )
            case .localOnly:
              SettingsNotice(
                title: "Credential Removed",
                message:
                  "The bridge was offline, so its Mac record may remain. Run “agentslate devices list”, then “agentslate devices revoke DEVICE_ID” on the Mac."
              )
            case .failed(let message):
              SettingsNotice(title: "Could Not Forget Bridge", message: message)
            }
        }
      }
    } message: {
      Text("This removes the saved device credential from this iPhone.")
    }
    .alert(item: $notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let build = info?["CFBundleVersion"] as? String ?? "3"
    return "\(version) (\(build))"
  }
}

private struct SettingsNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private struct AcknowledgementsView: View {
  var body: some View {
    ScrollView {
      Text(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .background(Palette.canvas)
    .navigationTitle("Acknowledgements")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var text: String {
    guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
      let value = try? String(contentsOf: url, encoding: .utf8)
    else {
      return "Acknowledgements are unavailable."
    }
    return value
  }
}

private enum Palette {
  static let canvas = Color(red: 0.956, green: 0.965, blue: 0.976)
  static let well = Color(red: 0.902, green: 0.922, blue: 0.945)
  static let keyFace = Color(red: 0.918, green: 0.936, blue: 0.955)
  static let keyLip = Color(red: 0.78, green: 0.81, blue: 0.85)
  static let line = Color(red: 0.817, green: 0.842, blue: 0.872)
  static let buttonIcon = Color(red: 0.18, green: 0.20, blue: 0.24)
  static let secondaryText = Color(red: 0.32, green: 0.35, blue: 0.4)
  static let shadow = Color(red: 0.15, green: 0.19, blue: 0.24)
  static let blue = Color.blue
  static let blueHighlight = Color(red: 0.24, green: 0.51, blue: 1)
  static let blueLip = Color(red: 0.025, green: 0.24, blue: 0.72)
  static let blocked = Color(red: 0.89, green: 0.22, blue: 0.20)
  static let done = Color(red: 0.10, green: 0.60, blue: 0.34)
  static let disabled = Color(red: 0.55, green: 0.58, blue: 0.63)
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

extension RemoteKey {
  fileprivate var symbol: String {
    switch self {
    case .arrowUp: "arrow.up"
    case .arrowDown: "arrow.down"
    case .arrowLeft: "arrow.left"
    case .arrowRight: "arrow.right"
    case .enter: "arrow.turn.down.left"
    case .escape: "escape"
    case .tab, .shiftTab: "arrow.right.to.line"
    case .space: "space"
    }
  }

  fileprivate var caption: String? {
    switch self {
    case .enter: "ENTER"
    case .escape: "ESC"
    case .tab: "TAB"
    case .shiftTab: "⇧ TAB"
    case .space, .arrowUp, .arrowDown, .arrowLeft, .arrowRight: nil
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
    case .shiftTab: "Shift Tab"
    case .space: "Space"
    }
  }
}
