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
              voiceProvider: model.voiceProvider,
              hasVoiceDraft: model.voiceDraft != nil,
              send: { key in Task { await model.send(key) } },
              sendAction: { action in Task { await model.send(action) } },
              retryVoice: {
                guard model.voiceDraft == nil else { return }
                Task { await model.prepareVoice() }
              }
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
            level: model.voiceLevel,
            provider: model.voiceProvider,
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
              voiceSelectionFeedback += 1
              model.beginVoice()
            },
            releaseVoice: { action in
              Task {
                await model.finishVoice(action)
                armedVoiceAction = .send
              }
            },
            cancelVoice: { Task { await model.cancelVoice(reprepare: true) } },
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
      guard !isShowing, model.voiceDraft == nil,
        model.hasConfiguration || model.isDemoMode
      else { return }
      Task { await model.prepareVoice() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        guard model.voiceDraft == nil,
          model.hasConfiguration || model.isDemoMode
        else { return }
        Task { await model.prepareVoice() }
      } else {
        Task { await model.cancelVoice() }
      }
    }
    .onChange(of: model.canSend) { _, canSend in
      Task {
        if canSend, model.voiceDraft == nil {
          await model.prepareVoice()
        } else {
          await model.cancelVoice()
        }
      }
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

private extension VoiceState {
  var isTalking: Bool {
    self == .starting || self == .listening
  }
}
