import AgentSlateClient
import SwiftUI

struct VoiceReviewView: View {
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

        if let notice = draft.notice {
          Label(notice, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Palette.blocked)
        }

        if draft.rawText != draft.text {
          Button("Use Raw Transcript") {
            text = draft.rawText
            selection = TextSelection(insertionPoint: text.endIndex)
          }
          .font(.footnote.weight(.semibold))
        }

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
        if case .failed = model.voiceState {
          sendError = model.errorMessage
        }
        selection = TextSelection(insertionPoint: text.endIndex)
        editorFocused = true
      }
    }
  }

  private var validation: VoiceTextValidation {
    validateVoicePromptText(text)
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
      return "\(validation.byteCount) of 8,192 UTF-8 bytes including the voice marker. Shorten the prompt to send it."
    case nil:
      if !targetAvailable {
        return "Reconnect and reselect \(draft.agentName) in \(draft.session) to send this draft."
      }
      return nil
    }
  }
}

struct SettingsView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var host: String
  @State private var code = ""
  @State private var openRouterAPIKey = ""
  @State private var sonioxAPIKey = ""
  @State private var pendingDictationEngine: DictationEngine?
  @State private var showingCloudConsent = false
  @State private var showingForgetConfirmation = false
  @State private var vocabularyInput = ""
  @State private var vocabularyError: String?
  @State private var editingVocabulary: VocabularyEditDraft?
  @State private var isAddingVocabulary = false
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

        Section {
          LabeledContent("Current Engine") {
            Menu(model.dictationEngine.label) {
              Button(DictationEngine.apple.label) { selectDictationEngine(.apple) }
                .disabled(!model.canUseDictationEngine(.apple))
              Button(DictationEngine.openRouter.label) { selectDictationEngine(.openRouter) }
                .disabled(!model.canUseDictationEngine(.openRouter))
              Button(DictationEngine.soniox.label) { selectDictationEngine(.soniox) }
                .disabled(!model.canUseDictationEngine(.soniox))
            }
          }

          Toggle(
            "Clean up transcripts",
            isOn: Binding(
              get: {
                model.dictationEngine != .apple && model.effectiveCloudCleanupEnabled
              },
              set: { enabled in
                Task { await model.setCloudCleanupEnabled(enabled) }
              }
            )
          )
          .disabled(model.dictationEngine == .apple || !model.hasOpenRouterAPIKey)

          if model.hasOpenRouterAPIKey {
            LabeledContent("OpenRouter API Key", value: "Saved")
          }

          SecureField("OpenRouter API key", text: $openRouterAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)

          Button(model.hasOpenRouterAPIKey ? "Replace OpenRouter Key" : "Save OpenRouter Key") {
            if model.saveOpenRouterAPIKey(openRouterAPIKey) {
              openRouterAPIKey = ""
            }
          }
          .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          if model.hasOpenRouterAPIKey {
            Button("Remove OpenRouter Key", role: .destructive) {
              Task { await model.removeOpenRouterAPIKey() }
            }
          }

          if model.hasSonioxAPIKey {
            LabeledContent("Soniox API Key", value: "Saved")
          }

          SecureField("Soniox API key", text: $sonioxAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)

          Button(model.hasSonioxAPIKey ? "Replace Soniox Key" : "Save Soniox Key") {
            if model.saveSonioxAPIKey(sonioxAPIKey) {
              sonioxAPIKey = ""
            }
          }
          .disabled(sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          if model.hasSonioxAPIKey {
            Button("Remove Soniox Key", role: .destructive) {
              Task { await model.removeSonioxAPIKey() }
            }
          }
        } header: {
          Text("Dictation")
        } footer: {
          Text(
            "Apple stays on-device. OpenRouter uses Whisper after recording. Soniox v5 shows live cloud transcription. Cloud failures fall back to Apple; cleanup uses your OpenRouter key."
          )
        }
        .alert(consentTitle, isPresented: $showingCloudConsent) {
          Button("Cancel", role: .cancel) {
            pendingDictationEngine = nil
          }
          Button("Enable") {
            guard let engine = pendingDictationEngine else { return }
            pendingDictationEngine = nil
            Task { await model.setDictationEngine(engine, grantingConsent: true) }
          }
        } message: {
          Text(consentMessage)
        }

        Section {
          HStack {
            TextField("Word or short phrase", text: $vocabularyInput)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit(addVocabularyTerm)
              .onChange(of: vocabularyInput) { _, _ in vocabularyError = nil }

            Button("Add", action: addVocabularyTerm)
              .disabled(
                isAddingVocabulary
                  || vocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )
          }

          if let vocabularyError {
            Label(vocabularyError, systemImage: "exclamationmark.triangle.fill")
              .font(.footnote)
              .foregroundStyle(Palette.blocked)
          }

          ForEach(model.vocabularyTerms, id: \.self) { term in
            Button {
              editingVocabulary = VocabularyEditDraft(term: term)
            } label: {
              HStack {
                Text(term)
                  .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "pencil")
                  .foregroundStyle(Palette.secondaryText)
              }
            }
            .swipeActions {
              Button("Delete", role: .destructive) {
                Task { await model.deleteVocabularyTerm(term) }
              }
            }
          }
        } header: {
          Text("Dictionary")
        } footer: {
          Text(
            "\(model.vocabularyTerms.count) of 100 terms. Short vocabulary hints improve recognition but cannot guarantee it. Terms stay on this iPhone in Apple mode; selected cloud transcription and cleanup providers receive them."
          )
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
    .sheet(item: $editingVocabulary) { draft in
      VocabularyEditSheet(term: draft.term) { newTerm in
        await model.updateVocabularyTerm(draft.term, to: newTerm)
      }
      .presentationDetents([.medium])
    }
  }

  private func addVocabularyTerm() {
    guard !isAddingVocabulary else { return }
    isAddingVocabulary = true
    vocabularyError = nil
    let term = vocabularyInput
    Task {
      let issue = await model.addVocabularyTerm(term)
      isAddingVocabulary = false
      if let issue {
        vocabularyError = issue.localizedDescription
      } else {
        vocabularyInput = ""
      }
    }
  }

  private func selectDictationEngine(_ engine: DictationEngine) {
    guard model.canUseDictationEngine(engine), engine != model.dictationEngine else { return }
    if model.hasDictationConsent(for: engine) {
      Task { await model.setDictationEngine(engine) }
    } else {
      pendingDictationEngine = engine
      showingCloudConsent = true
    }
  }

  private var consentTitle: String {
    "Enable \(pendingDictationEngine?.label ?? "Cloud Dictation")?"
  }

  private var consentMessage: String {
    switch pendingDictationEngine {
    case .openRouter:
      "Microphone audio and saved vocabulary terms will be sent through OpenRouter for Whisper transcription. "
        + "When cleanup is enabled, the transcript and vocabulary terms are sent through OpenRouter to Google. "
        + "The cleanup request requires Zero Data Retention routing."
    case .soniox:
      "Live microphone audio and saved vocabulary terms will be sent directly to Soniox. When cleanup is enabled, "
        + "the transcript and vocabulary terms are also sent through OpenRouter to Google."
    case .apple, nil:
      "Apple dictation stays on this iPhone."
    }
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    let build = info?["CFBundleVersion"] as? String ?? "5"
    return "\(version) (\(build))"
  }
}

private struct VocabularyEditDraft: Identifiable {
  let term: String
  var id: String { term }
}

private struct VocabularyEditSheet: View {
  let save: (String) async -> DictationVocabulary.Issue?

  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var errorMessage: String?
  @State private var isSaving = false

  init(
    term: String,
    save: @escaping (String) async -> DictationVocabulary.Issue?
  ) {
    self.save = save
    _text = State(initialValue: term)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Word or short phrase", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(saveTerm)
            .onChange(of: text) { _, _ in errorMessage = nil }

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.footnote)
              .foregroundStyle(Palette.blocked)
          }
        } footer: {
          Text("Use one or two words with the exact spelling and capitalization you want.")
        }
      }
      .scrollContentBackground(.hidden)
      .background(Palette.canvas)
      .navigationTitle("Edit vocabulary")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: saveTerm)
            .disabled(
              isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
      }
    }
  }

  private func saveTerm() {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    Task {
      let issue = await save(text)
      isSaving = false
      if let issue {
        errorMessage = issue.localizedDescription
      } else {
        dismiss()
      }
    }
  }
}

extension DictationEngine {
  fileprivate var label: String {
    switch self {
    case .apple: "Apple On-Device"
    case .openRouter: "OpenRouter Whisper"
    case .soniox: "Soniox v5 Real-Time"
    }
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
