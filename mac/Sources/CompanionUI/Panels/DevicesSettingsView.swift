// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CoreImage
import SwiftUI

/// The devices page of the settings: the paired devices, revocation, and opening a new pairing.
///
/// `DESIGN.md` section Mobil, Geraete-Token und Kopplung. A paired device never appears here by
/// its token — only its id, name, level and the two timestamps the daemon keeps.
struct DevicesSettingsView: View {
    @Bindable var controller: DevicesController

    @State private var newDeviceName = ""
    @State private var newDeviceLevel: DeviceLevel = .observe
    @State private var deviceToRevoke: Device?

    var body: some View {
        Form {
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            networkNotices
            devicesSection
            pairingSection
        }
        .formStyle(.grouped)
        .onAppear { controller.load() }
        .sheet(isPresented: Binding(
            get: { controller.pairing != nil },
            set: { open in if !open { controller.dismissPairing() } })
        ) {
            if let pairing = controller.pairing {
                PairingSheet(pairing: pairing) { controller.dismissPairing() }
            }
        }
        .confirmationDialog(
            "Gerät widerrufen?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { open in if !open { deviceToRevoke = nil } }),
            presenting: deviceToRevoke
        ) { device in
            Button("\(device.displayName) widerrufen", role: .destructive) {
                controller.revoke(device)
                deviceToRevoke = nil
            }
            Button("Abbrechen", role: .cancel) { deviceToRevoke = nil }
        } message: { device in
            Text("Laufende Verbindungen von \(device.displayName) werden sofort getrennt.")
        }
    }

    // MARK: - Warnings about the network port

    /// `DESIGN.md` section Mobil, Ferntransport und Identitaet und Vertrauen: a pairing carries
    /// an address, and two things can make that address useless before anybody scans it — the
    /// network port switched off, or a wildcard bind with no address set for a pairing to show
    /// instead. Both are said here, before somebody finds out at the phone.
    @ViewBuilder
    private var networkNotices: some View {
        if let network = controller.network {
            if !network.enabled {
                Section {
                    NoticeLine(text: """
                        Der Netzport ist ausgeschaltet. Eine Kopplung zeigt eine Adresse, die \
                        kein Gerät erreicht, bis network.enabled eingeschaltet ist.
                        """)
                }
            }
            if network.reach == .everything,
               network.advertiseAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    NoticeLine(text: """
                        Die Bindeadresse \(network.bindAddress) bindet jede Schnittstelle, sagt \
                        aber nicht, welche ein Gerät erreicht. Ohne eine eigene Adresse trägt \
                        der Kopplungs-QR \(network.bindAddress) – das erreicht kein Handy.
                        """)
                    TextField(
                        "Adresse, die ein Gerät erreicht, z. B. 100.64.0.3",
                        text: $controller.advertiseAddressDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(controller.isSavingAdvertiseAddress ? "Wird gesichert" : "Sichern") {
                        controller.saveAdvertiseAddress()
                    }
                    .disabled(controller.isSavingAdvertiseAddress)
                }
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section("Geräte") {
            if controller.isLoading, controller.devices.isEmpty {
                Text("Lädt...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if controller.devices.isEmpty {
                Text("Noch kein Gerät gekoppelt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.devices) { device in
                deviceRow(device)
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                Text("\(device.levelLabel) – \(seenText(device)) – \(stateText(device))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !device.isRevoked {
                Button("Widerrufen", role: .destructive) { deviceToRevoke = device }
                    .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(device.displayName), \(device.levelLabel), \(seenText(device)), \(stateText(device))")
    }

    private func seenText(_ device: Device) -> String {
        guard let seenMs = device.lastSeenMs else { return "nie verbunden" }
        let date = Date(timeIntervalSince1970: Double(seenMs) / 1000)
        return "zuletzt \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func stateText(_ device: Device) -> String {
        device.isRevoked ? "widerrufen" : "aktiv"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()

    // MARK: - Pairing a new device

    private var pairingSection: some View {
        Section("Gerät koppeln") {
            LabeledContent("Name") {
                TextField("z. B. iPhone", text: $newDeviceName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Stufe", selection: $newDeviceLevel) {
                ForEach(DeviceLevel.all, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            Text(newDeviceLevel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(controller.isCreatingPairing ? "Kopplung wird erzeugt" : "Kopplung erzeugen") {
                controller.createPairing(deviceName: newDeviceName, level: newDeviceLevel)
            }
            .disabled(controller.isCreatingPairing)
        }
    }
}

/// The QR code, the short code, the fingerprint and everything else a person needs to pair a
/// device by scanning or by typing.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen: the short code is shown in two groups
/// of four and the fingerprint in groups of four, the only way somebody actually compares one
/// against a screen.
struct PairingSheet: View {
    let pairing: PairingOffer
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Gerät koppeln")
                .font(.headline)

            if let image = Self.qrImage(for: pairing.uri) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("QR-Code zum Koppeln von \(pairing.deviceName)")
            } else {
                Text("""
                    QR-Code konnte nicht erzeugt werden. Kurzcode und Adresse reichen zum \
                    Koppeln von Hand.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Gerät", value: pairing.deviceName)
                LabeledContent("Stufe", value: pairing.level.label)
                LabeledContent("Maschine", value: pairing.machine.label)
                LabeledContent("Adresse", value: pairing.address)
                LabeledContent("Kurzcode", value: pairing.groupedShortCode)
                // A `LabeledContent` value truncates to one line, and the grouped fingerprint
                // (64 hex characters plus spaces) never fits one at this width - a wrapped row
                // of its own is what keeps every character checkable.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fingerabdruck")
                    Text(pairing.groupedFingerprint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Gültig noch", value: "\(pairing.remainingMinutes()) Minuten")
            }
            .textSelection(.enabled)

            Text("""
                Ein falscher Code beendet diese Kopplung sofort; eine neue lässt sich \
                jederzeit erzeugen.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Fertig", action: onDone)
        }
        .padding(24)
        .frame(width: 320)
    }

    /// Rendered locally with CoreImage — no external package for a QR code nobody needs one
    /// for.
    private static func qrImage(for content: String) -> NSImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 8.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
