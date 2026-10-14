// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionMobile
import CompanionProtocol
import SwiftUI

/// Pairing a machine, in the three ways `DESIGN.md` section Mobil names.
///
/// The camera is asked for in the step that uses it and nowhere else, and what it is for is on
/// the screen before the system dialog appears — the HIG asks for exactly that order.
struct PairingView: View {
    let app: AppModel
    /// True while there is no machine at all: then this is the whole app and has no way out.
    var isFirstMachine = false
    @Environment(\.dismiss) private var dismiss
    @State private var flow = PairingFlow()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        """
                        Der Companion läuft auf deinem Rechner. Damit dieses Gerät ihn \
                        erreicht, koppelst du es einmal: Die Mac-Shell oder das \
                        Terminal-Werkzeug zeigt dir dafür einen QR-Code.
                        """
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section("Weg wählen") {
                    NavigationLink {
                        ScanStepView(flow: flow)
                    } label: {
                        way(.scan)
                    }
                    .accessibilityIdentifier("weg-scan")
                    NavigationLink {
                        TypedCodeView(flow: flow)
                    } label: {
                        way(.shortCode)
                    }
                    .accessibilityIdentifier("weg-shortCode")
                    NavigationLink {
                        ManualEntryView(flow: flow)
                    } label: {
                        way(.manual)
                    }
                    .accessibilityIdentifier("weg-manual")
                }

                Section {
                    Text(
                        """
                        Der Netzzugang des Daemons ist ab Werk aus. Schalte ihn in der \
                        Mac-Shell unter Geräte ein, bevor du hier koppelst.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isFirstMachine ? "Willkommen" : "Maschine koppeln")
            .toolbar {
                if !isFirstMachine {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            flow.existingMachineIds = Set(app.connections.map(\.id))
            flow.onPaired = { machine in
                app.add(machine)
                if !isFirstMachine { dismiss() }
            }
        }
    }

    private func way(_ way: PairingWay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(way.label)
            Text(way.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The camera step: what it is for, then the picture.
struct ScanStepView: View {
    let flow: PairingFlow
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isScanning = false
    /// Set when the camera could not be set up at all — a simulator, or a device without one.
    /// The permission dialog answers a different question, so this needs its own line.
    @State private var hasNoCamera = false

    var body: some View {
        VStack(spacing: 20) {
            switch access {
            case _ where hasNoCamera:
                explanation(
                    """
                    Dieses Gerät hat keine Kamera, die den Code lesen könnte. Der Kurzcode aus \
                    demselben Kopplungsvorgang geht auch ohne.
                    """)
            case .authorized where isScanning:
                CodeScannerView(
                    onCode: { text in
                        isScanning = false
                        flow.scanned(text)
                    },
                    onUnavailable: {
                        isScanning = false
                        hasNoCamera = true
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
                .accessibilityLabel("Kamerabild zum Lesen des Kopplungscodes")
            case .denied, .restricted:
                explanation(
                    """
                    Die Kamera ist für diese App gesperrt. In den Systemeinstellungen unter \
                    Datenschutz lässt sie sich wieder freigeben. Ohne Kamera bleibt der \
                    Kurzcode.
                    """)
            default:
                explanation(
                    """
                    Für diesen Schritt liest die Kamera einmal den QR-Code auf deinem \
                    Bildschirm. Sie läuft nur, solange dieser Bildschirm offen ist, und es \
                    wird nichts aufgenommen.
                    """)
                Button("Kamera starten") { start() }
                    .buttonStyle(.borderedProminent)
            }

            if flow.isWorking {
                ProgressView("Koppelt …")
            }
            if let failure = flow.failureText {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Noch einmal versuchen") { start() }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("QR-Code scannen")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { isScanning = false }
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
    }

    private func start() {
        flow.reset()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .authorized
            isScanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    access = granted ? .authorized : .denied
                    isScanning = granted
                }
            }
        default:
            access = .denied
        }
    }
}

/// The short code out of the same pairing, with the two fields it needs beside it.
struct TypedCodeView: View {
    @Bindable var flow: PairingFlow

    var body: some View {
        Form {
            Section("Maschine") {
                TextField("Adresse, zum Beispiel 100.64.0.7:47801", text: $flow.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Fingerabdruck des Zertifikats", text: $flow.fingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Section("Kopplungscode") {
                TextField("Achtstelliger Code", text: $flow.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Section {
                Button("Koppeln") { flow.redeemTypedCode() }
                    .disabled(!flow.canRedeemTypedCode)
            } footer: {
                Text(
                    """
                    Adresse und Fingerabdruck stehen in der Mac-Shell neben dem QR-Code. \
                    Der Fingerabdruck ist das, woran dieses Gerät den Daemon wiedererkennt.
                    """)
            }
            outcome(flow)
        }
        .navigationTitle("Kurzcode eingeben")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The debug way: this device already has its token.
struct ManualEntryView: View {
    @Bindable var flow: PairingFlow
    @State private var isConfirmingOverwrite = false

    var body: some View {
        Form {
            Section("Maschine") {
                TextField("Adresse, zum Beispiel 100.64.0.7:47801", text: $flow.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Fingerabdruck des Zertifikats", text: $flow.fingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("Maschinenkennung", text: $flow.machineId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Name der Maschine, optional", text: $flow.machineName)
            }
            Section("Geräte-Token") {
                TextField("Token", text: $flow.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Section {
                if flow.overwritesExistingMachine {
                    Label(
                        "Diese Maschine ist schon gekoppelt. Speichern ersetzt ihr Token und "
                            + "ihr Zertifikat.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    Button("Vorhandene Kopplung ersetzen", role: .destructive) {
                        isConfirmingOverwrite = true
                    }
                    .disabled(!flow.canSaveManually)
                } else {
                    Button("Speichern") { flow.saveManually() }
                        .disabled(!flow.canSaveManually)
                }
            } footer: {
                Text(
                    """
                    Hier wird nichts eingelöst. Welche Stufe das Token trägt, weiß der Daemon. \
                    Die App trägt sie deshalb als unbekannt ein, lässt jeden Versuch hinaus und \
                    zeigt, was der Daemon antwortet.
                    """)
            }
            outcome(flow)
        }
        .navigationTitle("Von Hand eintragen")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Kopplung ersetzen?", isPresented: $isConfirmingOverwrite, titleVisibility: .visible
        ) {
            Button("Ersetzen", role: .destructive) { flow.saveManually() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                """
                Token und Zertifikat der bisherigen Kopplung sind danach weg. Sie lassen sich \
                nur durch eine neue Kopplung zurückholen.
                """)
        }
    }
}

/// What the last attempt did, under the form that started it.
@MainActor
@ViewBuilder
private func outcome(_ flow: PairingFlow) -> some View {
    if flow.isWorking {
        Section { ProgressView("Koppelt …") }
    } else if let failure = flow.failureText {
        Section {
            Text(failure).foregroundStyle(.red)
        }
    }
}
