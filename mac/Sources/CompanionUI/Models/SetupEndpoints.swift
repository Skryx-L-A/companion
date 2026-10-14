// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// The local speech setup the assistant offers, in one place.
///
/// `DESIGN.md` section Endpoints: local, Peer and cloud are only different URLs, and the
/// local one here is the pair the voice track measured against — one `mlx_audio.server` that
/// serves both roles, Breeze TTS 2 for the output and parakeet for the recognition. Kokoro
/// stays directly behind Breeze as the fallback. The Breeze profile comes from
/// `CompanionProtocol`, the same profile constructor the daemon mirrors for `adopt_breeze`.
public enum LocalSpeechSetup {
    /// Program name of the speech server, as it is installed.
    public static let serverProgram = "mlx_audio.server"
    public static let host = "127.0.0.1"
    public static let port = 8791

    public static var baseURL: String { "http://\(host):\(port)" }
    /// Any answer counts as ready, this route included: what is established is that the
    /// server listens and serves.
    public static var readyURL: String { "\(baseURL)/v1/models" }

    public static let recogniserId = "mlx-audio-stt"
    public static let recogniserModel = "mlx-community/parakeet-tdt-0.6b-v3"
    public static let kokoroId = "mlx-audio-tts"
    public static let kokoroModel = "mlx-community/Kokoro-82M-bf16"
    /// Kokoro has its own set of voice names and refuses the OpenAI ones, so the default
    /// travels with the profile.
    public static let kokoroVoice = "af_heart"

    /// The `say` program of macOS, the fallback that needs nothing installed.
    public static let sayId = "macos-say"
    public static let sayPath = "/usr/bin/say"

    /// The German voice profile of `say`, kept apart from the plain fallback above.
    ///
    /// Kokoro-82M has no German phonemes at all — it knows American and British English,
    /// Spanish, French, Hindi, Italian, Portuguese, Japanese and Mandarin, and reads German
    /// text in one of those instead, which is what Skryx-L-A heard on 2026-08-27. `say`'s
    /// `Anna` is the German voice macOS ships installed by default (`de_DE`, confirmed with
    /// `say -v '?'`); the daemon's language-aware TTS routing moves this profile to the front
    /// of the chain for a sentence it detects as German, tagged `de` below.
    public static let sayDeId = "macos-say-de"
    public static let sayGermanVoice = "Anna"

    /// `piper` (`OHF-voice/piper1-gpl`, the actively maintained fork of the archived
    /// `rhasspy/piper`; GPL-3.0-or-later), the German voice Skryx-L-A's own ear judged clearly
    /// better than `say`'s `Anna` on 2026-08-27 — see the spur `stimme2` result for the
    /// comparison. Invoked only as a subprocess, the same arrangement as `say`, so its
    /// license does not reach into this app.
    ///
    /// `piper` is an optional install (`uv tool install piper-tts`) plus a model download,
    /// not something every machine has, so it is added to the chain only when both the
    /// program and a model are actually found — the same gating `installedSpeechServer`
    /// already does for the `mlx_audio.server` pair.
    public static let piperId = "piper-de"
    public static let piperProgram = "piper"
    /// The voice measured against `say`'s `Anna`: `de_DE-thorsten-high`, the higher-quality
    /// of the two sizes loaded for that comparison (`de_DE-thorsten-medium` is the other).
    /// One line to change if an ear decides the medium model is the better trade.
    public static let piperModelFile = "de_DE-thorsten-high.onnx"

    public static var piperVoicesDirectory: URL {
        CompanionPaths().configDirectory.appendingPathComponent("voice-models")
    }

    public static var piperModelPath: URL {
        piperVoicesDirectory.appendingPathComponent(piperModelFile)
    }

    /// Where `piper` is on this machine, or nil when it is not installed.
    public static func installedPiper() -> String? {
        ToolDetection.path(of: piperProgram)
    }

    /// Whether the model the profile expects was actually loaded onto this machine.
    public static func installedPiperModel() -> Bool {
        FileManager.default.isReadableFile(atPath: piperModelPath.path)
    }

    public static func piper(program: String, model: String) -> EndpointProfile {
        EndpointProfile(
            id: piperId, protocolKind: .cli, url: program, model: model, language: "de")
    }

    public static var recogniser: EndpointProfile {
        EndpointProfile(
            id: recogniserId, protocolKind: .openaiCompat, url: baseURL,
            model: recogniserModel)
    }

    public static var kokoro: EndpointProfile {
        EndpointProfile(
            id: kokoroId, protocolKind: .openaiCompat, url: baseURL,
            model: kokoroModel, voice: kokoroVoice, language: "en")
    }

    /// The same transition as `adopt_breeze`: Breeze takes the URL of the setup's Kokoro
    /// profile, and Kokoro remains available directly behind it.
    public static var speaker: EndpointProfile {
        EndpointProfile.breeze(url: kokoro.url)
    }

    public static var say: EndpointProfile {
        EndpointProfile(id: sayId, protocolKind: .cli, url: sayPath)
    }

    public static var sayGerman: EndpointProfile {
        EndpointProfile(
            id: sayDeId, protocolKind: .cli, url: sayPath, voice: sayGermanVoice,
            language: "de")
    }

    /// Whether the system's own language is German, the signal the setup uses to decide
    /// whether to add [`sayGerman`] to the chain unasked. `Locale.current` reflects the
    /// person's actual system preference (Settings > General > Language & Region), not the
    /// app's own UI-language fallback.
    public static func systemLanguageIsGerman(locale: Locale = .current) -> Bool {
        locale.language.languageCode?.identifier == "de"
    }

    /// The command line the daemon starts the server with, for a program at `path`.
    public static func serverCommand(at path: String) -> [String] {
        [path, "--host", host, "--port", String(port)]
    }

    /// Where the speech server is on this machine, or nil when it is not installed.
    public static func installedServer() -> String? {
        ToolDetection.path(of: serverProgram)
    }

    /// Whether the speech server's Hugging Face cache holds a complete Breeze snapshot.
    ///
    /// This follows the daemon's `hub_cache` and `hub_has_model` rules: the server's explicit
    /// environment wins, and a snapshot counts only with both its configuration and finished
    /// safetensor weights. Merely starting the server to ask would load gigabytes.
    public static func breezeWeightsAreInstalled(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let cache: URL
        if let path = environment["HF_HUB_CACHE"] {
            cache = URL(fileURLWithPath: path)
        } else if let path = environment["HF_HOME"] {
            cache = URL(fileURLWithPath: path).appendingPathComponent("hub")
        } else {
            cache = homeDirectory.appendingPathComponent(".cache/huggingface/hub")
        }
        let repository = "models--\(EndpointProfile.breezeModel.replacingOccurrences(of: "/", with: "--"))"
        let snapshots = cache.appendingPathComponent(repository).appendingPathComponent("snapshots")
        guard let directories = try? fileManager.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }

        return directories.contains { snapshot in
            let config = snapshot.appendingPathComponent("config.json")
            guard fileManager.fileExists(atPath: config.path),
                  let files = try? fileManager.contentsOfDirectory(
                    at: snapshot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return false }
            return files.contains {
                $0.pathExtension == "safetensors" && fileManager.fileExists(atPath: $0.path)
            }
        }
    }
}

/// The chat model the assistant offers to connect.
///
/// `DESIGN.md` section Endpoints names two execution models and recommends the API profile
/// for the chat model. Both are offered here, and both are limited to what the daemon can
/// actually drive today: the CLI way runs `claude -p`, and the API way speaks the
/// OpenAI-compatible shape. A profile the daemon would refuse is not on the list.
public enum ChatSetup {
    public static let cliProfileId = "claude-cli"
    public static let apiProfileId = "chat-api"
    /// Fixed arguments the CLI profile carries. `--safe-mode` first, in front of whatever the
    /// driver adds (`-p`, the output format, the model).
    ///
    /// Measured 2026-08-27, same prompt both times: `claude -p` without it loads this
    /// machine's whole user configuration into the companion's chat turn — global CLAUDE.md,
    /// hooks, the caveman plugin — and the companion answers as that foreign persona instead
    /// of its own; a cloud question came back as the fragment "Wolke ist Menge aus…" instead
    /// of a full sentence. `--safe-mode` skips all of that and the subscription login still
    /// carries the run.
    public static let cliArgs = ["--safe-mode"]

    /// A CLI profile for the `claude` program at `path`.
    public static func cli(at path: String) -> EndpointProfile {
        EndpointProfile(id: cliProfileId, protocolKind: .cli, url: path, args: cliArgs)
    }

    /// A chat server that runs on this machine, in the shape the setup can offer it.
    public struct LocalServer: Sendable, Equatable {
        /// The program `ToolDetection` looks for, the same way the setup finds `claude`.
        public let program: String
        public let label: String
        /// The address it serves the OpenAI shape under, without the `/v1` the daemon adds.
        public let url: String
    }

    /// The two local servers this house actually runs. Ollama serves its own OpenAI-compatible
    /// route under the same port; `mlx_lm.server` is the MLX side.
    public static let localServers = [
        LocalServer(program: "ollama", label: "Ollama", url: "http://127.0.0.1:11434"),
        LocalServer(program: "mlx_lm.server", label: "MLX", url: "http://127.0.0.1:8080"),
    ]

    /// Those of them that are installed here. Detection is the program on disk, exactly as for
    /// `claude` — not a request to a port, which would answer nothing while the server is
    /// stopped and would hold the panel while it is not.
    public static func installedLocalServers(
        locate: (String) -> String? = { ToolDetection.path(of: $0) }
    ) -> [LocalServer] {
        localServers.filter { locate($0.program) != nil }
    }

    /// What a person needs to know before they put a local model on the chat role.
    ///
    /// The measurement is this machine's own, and it did not come out in the local model's
    /// favour, so the sentence says that rather than selling it. Kept next to the offer
    /// because the offer without it would be a recommendation nothing supports.
    public static let localServerNote = """
        Gemessen am 05.09.2026 auf dieser Maschine, fünf Fragen mal drei Läufe: Das Gespräch \
        bleibt damit ganz auf dem Rechner, aber die beiden lokalen Modelle haben die Werkzeuge \
        kaum getroffen — das große antwortete erst nach gut dreißig Sekunden, das kleine nach \
        einer Sekunde und erfand die Antwort, statt nachzusehen. Wer es einträgt, prüft danach \
        an einer echten Frage, ob die Werkzeuge laufen.
        """

    public static func api(url: String, model: String?, keyRef: String?) -> EndpointProfile {
        EndpointProfile(
            id: apiProfileId, protocolKind: .openaiCompat,
            url: url.trimmingCharacters(in: .whitespaces),
            keyRef: keyRef?.isEmpty == true ? nil : keyRef,
            model: model?.isEmpty == true ? nil : model)
    }
}

/// The endpoints the setup assistant writes, and what it knows about them.
///
/// `DESIGN.md` section Ersteinrichtung asks the setup to connect the models, not to point at
/// the page where somebody else could. Until this existed the assistant only opened the
/// endpoints page, which is why a machine could finish the quick start and still have neither
/// speech recognition nor a chat model — the state the first real first start ended in.
///
/// Everything goes through `DaemonSettingsStore`, so the daemon stays the owner of the
/// document and refuses whatever it would refuse from any other page.
@MainActor
@Observable
public final class SetupEndpointsController {
    /// The document as it was last read, or nil while none was read.
    public private(set) var settings: DaemonSettings?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    /// The last thing that happened, in one line. Nil while there is nothing to say.
    public private(set) var notice: String?
    /// True when this daemon has no request for the settings document at all.
    public private(set) var isDaemonWriteMissing = false
    /// Where the speech server is installed, filled by `load`. Nil when it is not there.
    public private(set) var installedSpeechServer: String?
    /// Where `piper` is installed, filled the same way. Nil when it is not there.
    public private(set) var installedPiperProgram: String?
    /// The `piper` model file this machine has loaded, filled the same way. Nil when it is
    /// missing — `piper` without its model is not a usable profile.
    public private(set) var installedPiperModel: String?
    /// Whether the server's configured cache already has complete Breeze weights.
    public private(set) var hasBreezeWeights = false
    /// Whether the daemon is to start the speech server itself once speech is connected.
    ///
    /// Off unless a person switches it on, with the warning next to the switch. It lives here
    /// rather than in the view because it is an answer and not a piece of view state: leaving
    /// the question and coming back must not silently drop it.
    public var letsDaemonStartServer = false

    private let store: DaemonSettingsStore
    /// Where the speech server is. A parameter rather than a call, so a test says what this
    /// machine has instead of depending on what it happens to have installed.
    private let locateSpeechServer: () -> String?
    /// Where `piper` is, for the same reason as `locateSpeechServer`.
    private let locatePiperProgram: () -> String?
    /// The `piper` model this machine has, for the same reason as `locateSpeechServer`.
    private let locatePiperModel: () -> String?
    /// Looks only at the cache the settings give the speech server; injected so tests do not
    /// depend on what the developer machine happens to have downloaded.
    private let locateBreezeWeights: ([String: String]) -> Bool
    /// Whether the system language is German. A parameter for the same reason as
    /// `locateSpeechServer`: a test says what this machine's language is instead of depending
    /// on whoever happens to run it.
    private let systemLanguageIsGerman: () -> Bool

    public init(
        store: DaemonSettingsStore,
        locateSpeechServer: @escaping () -> String? = { LocalSpeechSetup.installedServer() },
        locatePiperProgram: @escaping () -> String? = { LocalSpeechSetup.installedPiper() },
        locatePiperModel: @escaping () -> String? = {
            LocalSpeechSetup.installedPiperModel() ? LocalSpeechSetup.piperModelPath.path : nil
        },
        locateBreezeWeights: @escaping ([String: String]) -> Bool = {
            LocalSpeechSetup.breezeWeightsAreInstalled(environment: $0)
        },
        systemLanguageIsGerman: @escaping () -> Bool = { LocalSpeechSetup.systemLanguageIsGerman() }
    ) {
        self.store = store
        self.locateSpeechServer = locateSpeechServer
        self.locatePiperProgram = locatePiperProgram
        self.locatePiperModel = locatePiperModel
        self.locateBreezeWeights = locateBreezeWeights
        self.systemLanguageIsGerman = systemLanguageIsGerman
    }

    // MARK: - What is set up

    private func hasRole(_ role: EndpointRole) -> Bool {
        guard let settings else { return false }
        return !settings.endpoints.chain(role).isEmpty
    }

    public var hasSpeechRecognition: Bool { hasRole(.stt) }
    public var hasSpeechOutput: Bool { hasRole(.tts) }
    public var hasChatModel: Bool { hasRole(.chatLlm) }
    /// True once the daemon starts the speech server itself.
    public var startsSpeechServer: Bool { settings?.voiceServer.enabled ?? false }
    /// True once the document was read, so a button can say what it would do.
    public var hasSettings: Bool { settings != nil }

    /// Full setup's Finish button asks the settings bridge to apply the saved tier after
    /// its answers have reached the daemon. A cancelled run clears that request.
    public func applySkillsAfterSetupAnswers() {
        store.applySkillsAfterSetupAnswers()
    }

    public func cancelSkillApplyAfterSetupAnswers() {
        store.cancelSkillApplyAfterSetupAnswers()
    }

    /// The profile that serves a role, for the line the assistant shows.
    public func primaryProfile(_ role: EndpointRole) -> EndpointProfile? {
        settings?.endpoints.chain(role).first
    }

    // MARK: - Reading

    /// Takes a document somebody else already read, and looks for the speech server.
    ///
    /// The shell reads the settings on every handshake; asking for them a second time here
    /// would be a request for something it already has.
    public func adopt(_ settings: DaemonSettings) {
        installedSpeechServer = locateSpeechServer()
        installedPiperProgram = locatePiperProgram()
        installedPiperModel = locatePiperModel()
        hasBreezeWeights = locateBreezeWeights(settings.voiceServer.env)
        isDaemonWriteMissing = false
        self.settings = settings
    }

    /// Reads the document and looks for the speech server. Called every time a step that
    /// needs it appears; a read while one is in flight is dropped rather than queued.
    public func refresh() {
        installedSpeechServer = locateSpeechServer()
        installedPiperProgram = locatePiperProgram()
        installedPiperModel = locatePiperModel()
        guard !isLoading, !isSaving else { return }
        isLoading = true
        store.loadSettings { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let settings):
                self.isDaemonWriteMissing = false
                self.hasBreezeWeights = self.locateBreezeWeights(settings.voiceServer.env)
                self.settings = settings
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    // MARK: - Writing

    /// Connects the local speech pair and, when asked for it, lets the daemon start the
    /// server itself.
    ///
    /// Starting a program named in a settings file is a high-risk setting: the confirmation
    /// travels only because a person pressed the button that carries the warning, which is
    /// the same rule the security page follows. Without `startingTheServer` nothing high-risk
    /// is sent and the daemon expects a server somebody started.
    public func connectLocalSpeech(
        startingTheServer: Bool, completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard var wanted = settings else { return refuseWithoutDocument(completion) }
        var endpoints = wanted.endpoints
        upsert(LocalSpeechSetup.recogniser, into: &endpoints)
        upsert(LocalSpeechSetup.speaker, into: &endpoints)
        upsert(LocalSpeechSetup.kokoro, into: &endpoints)
        // The fallback that needs nothing installed. Present on a fresh daemon; put back
        // here for a document somebody had emptied.
        upsert(LocalSpeechSetup.say, into: &endpoints)
        endpoints.roles[.stt] = RoleBinding(primary: LocalSpeechSetup.recogniserId)
        let englishFallback = LocalSpeechSetup.kokoro.id
        // A German system also gets `say`'s German voice in the chain, tagged so the
        // daemon's language-aware routing reaches for it on a German sentence instead of
        // reading it with Kokoro's English phonemes. Left out on any other system: nothing
        // here should claim a voice nobody asked for.
        if systemLanguageIsGerman() {
            upsert(LocalSpeechSetup.sayGerman, into: &endpoints)
            // `piper` goes in front of `say`/`Anna` when it is actually usable on this
            // machine — both the program and its model have to be there, since a profile
            // pointing at a missing model would just fail and fall through anyway, one
            // avoidable failed attempt on every German sentence.
            var germanFallback = [LocalSpeechSetup.sayDeId, LocalSpeechSetup.sayId]
            if let program = installedPiperProgram, let model = installedPiperModel {
                upsert(LocalSpeechSetup.piper(program: program, model: model), into: &endpoints)
                germanFallback = [LocalSpeechSetup.piperId] + germanFallback
            }
            endpoints.roles[.tts] = RoleBinding(
                primary: LocalSpeechSetup.speaker.id,
                fallback: [englishFallback] + germanFallback)
        } else {
            endpoints.roles[.tts] = RoleBinding(
                primary: LocalSpeechSetup.speaker.id,
                fallback: [englishFallback, LocalSpeechSetup.sayId])
        }
        wanted.endpoints = endpoints

        if startingTheServer, let path = installedSpeechServer {
            wanted.voiceServer.enabled = true
            wanted.voiceServer.command = LocalSpeechSetup.serverCommand(at: path)
            wanted.voiceServer.readyURL = LocalSpeechSetup.readyURL
        }
        save(
            wanted,
            saying: startingTheServer
                ? "Sprache eingerichtet. Der Daemon startet den Sprachserver beim ersten Sprechen."
                : "Sprache eingerichtet. Der Sprachserver muss laufen, bevor du sprichst.",
            // The one raise this method can carry is the daemon starting the server, and the
            // switch that asks for it renders `speechServerWarnings()` above the button that
            // gets here (`SetupStepView`, Punkt 6).
            confirmHighRisk: startingTheServer,
            completion: completion)
    }

    /// Connects `claude` as the chat model, over the subscription and without a key.
    ///
    /// The same profile takes the helper role as well, unless something is bound there
    /// already. Nobody wrote that role before: this assistant set `chatLlm` and nothing else,
    /// the daemon's own defaults set neither, and so `web_research` refused every question
    /// and no long tool result was ever shortened — on Skryx-L-A's own machine until
    /// 2026-09-05. Only here and not in `connectChatApi`, because searching the web needs a
    /// profile that starts the `claude` program; an API profile in that role would shorten
    /// results and still refuse every research question.
    public func connectChatCli(
        at path: String, completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard var wanted = settings else { return refuseWithoutDocument(completion) }
        var endpoints = wanted.endpoints
        upsert(ChatSetup.cli(at: path), into: &endpoints)
        endpoints.roles[.chatLlm] = RoleBinding(primary: ChatSetup.cliProfileId)
        if endpoints.roles[.subagentLlm] == nil {
            endpoints.roles[.subagentLlm] = RoleBinding(primary: ChatSetup.cliProfileId)
        }
        wanted.endpoints = endpoints
        save(
            wanted, saying: "Chat-Modell verbunden: \(path) über das Abo, ohne Schlüssel.",
            completion: completion)
    }

    /// Connects an OpenAI-compatible endpoint as the chat model.
    ///
    /// `keyRef` is the name of a keychain entry, never a key. The daemon refuses a key that
    /// was pasted here, and so does the check in front of it.
    public func connectChatApi(
        url: String, model: String, keyRef: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard var wanted = settings else { return refuseWithoutDocument(completion) }
        let address = url.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            notice = "Ohne Adresse lässt sich kein Endpoint anlegen."
            return completion(false)
        }
        guard !urlHasUserinfo(address) else {
            notice = """
                In der Adresse steht eine Anmeldung. Ein Schlüssel gehört unter einen Namen \
                in den Schlüsselbund, nicht in die Adresse.
                """
            return completion(false)
        }
        let name = keyRef.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty || isNameNotKey(name) else {
            notice = """
                Hier steht der Name eines Schlüsselbund-Eintrags, nicht der Schlüssel selbst.
                """
            return completion(false)
        }
        var endpoints = wanted.endpoints
        upsert(
            ChatSetup.api(url: address, model: model, keyRef: name.isEmpty ? nil : name),
            into: &endpoints)
        endpoints.roles[.chatLlm] = RoleBinding(primary: ChatSetup.apiProfileId)
        wanted.endpoints = endpoints
        save(wanted, saying: "Chat-Modell verbunden: \(address).", completion: completion)
    }

    /// Puts a document this assistant wrote back the way it was.
    ///
    /// `DESIGN.md` section Ersteinrichtung: an abort leaves standards behind, never half a
    /// state. `OnboardingFlow.cancel` restored the shell's own answers and nothing else, so
    /// pressing "Lokal einrichten" and then Abbrechen left the daemon permanently allowed to
    /// start that program — a high-risk setting the person had visibly backed out of (review,
    /// 2026-09-03).
    ///
    /// Nothing is sent when nothing changed. Putting a document back normally only lowers — it
    /// is the state the daemon was in a moment ago — and a restore that would raise something
    /// all the same is not sent at all: a confirmation nobody gave must not travel, and the
    /// daemon would refuse it anyway.
    public func restore(_ document: DaemonSettings, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let current = settings, current != document else { return completion(true) }
        guard document.highRiskRaises(comparedTo: current).isEmpty else {
            notice = """
                Der Abbruch lässt sich nicht vollständig zurücknehmen: was vorher galt, wäre \
                jetzt eine Hochrisiko-Einstellung. Sie steht auf der Einstellungsseite.
                """
            return completion(false)
        }
        save(document, saying: "Die Einrichtung wurde abgebrochen. Es bleibt, wie es war.",
             completion: completion)
    }

    private func refuseWithoutDocument(_ completion: (Bool) -> Void = { _ in }) {
        notice = """
            Die Einstellungen des Daemons wurden nie gelesen, deshalb wird hier nichts \
            geschrieben. Sobald die Verbindung steht, geht es.
            """
        completion(false)
    }

    /// Replaces a profile of the same name, or appends it. A second `mlx-audio-stt` would be
    /// exactly the duplicate the daemon refuses.
    private func upsert(_ profile: EndpointProfile, into config: inout EndpointConfig) {
        if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
            config.profiles[index] = profile
        } else {
            config.profiles.append(profile)
        }
    }

    /// - Parameter confirmHighRisk: true only where the caller knows a person pressed the
    ///   button that carries the warning. It used to be derived from the diff itself
    ///   (`!raises.isEmpty`), which meant every caller that happened to raise something got
    ///   the confirmation granted by the very fact of raising it — the opposite of what
    ///   `SettingsBridge` writes one file over, that the flag belongs to the person and to
    ///   nobody else (review, 2026-09-03). The assertion below is the guard rail: a raise
    ///   without a confirmation is a caller that has to be fixed, not a document to send.
    private func save(
        _ wanted: DaemonSettings, saying line: String, confirmHighRisk: Bool = false,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard let current = settings else { return refuseWithoutDocument(completion) }
        let raises = wanted.highRiskRaises(comparedTo: current)
        assert(
            raises.isEmpty || confirmHighRisk,
            "high-risk raise without a human confirmation: \(raises.joined(separator: "; "))")
        isSaving = true
        notice = nil
        store.saveSettings(wanted, confirmHighRisk: confirmHighRisk) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success:
                self.settings = wanted
                self.notice = line
                return completion(true)
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
                self.notice = EndpointStoreFailure.notInProtocol.message
            case .failure(let failure):
                self.notice = failure.message
            }
            completion(false)
        }
    }

    /// What switching the speech server on would raise, in the daemon's own words. Empty
    /// while nothing would be raised, which is also the case once it is already on.
    public func speechServerWarnings() -> [String] {
        guard let current = settings, let path = installedSpeechServer else { return [] }
        var wanted = current
        wanted.voiceServer.enabled = true
        wanted.voiceServer.command = LocalSpeechSetup.serverCommand(at: path)
        wanted.voiceServer.readyURL = LocalSpeechSetup.readyURL
        return wanted.highRiskRaises(comparedTo: current)
    }

    /// A missing model is visible but never blocks saving the setup. The script is named here
    /// because the assistant must not imply that pressing its button downloads anything.
    public var missingBreezeWeightsNotice: String? {
        guard installedSpeechServer != nil, !hasBreezeWeights else { return nil }
        return "Die Breeze-TTS-2-Gewichte fehlen; install-speech.sh lädt sie, und du kannst die Einrichtung trotzdem abschließen."
    }
}
