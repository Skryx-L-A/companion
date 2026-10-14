// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The register: what ran on this machine, what it answered by itself, and what it cost.
///
/// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren": every self-answer is written
/// into the register with question, answer and source "und ist im Panel nachlesbar". This is
/// that panel, and the self-answers are the reason it exists — they sit one click under the
/// run they belong to rather than in a page of their own, because the question a person has
/// is "what did it decide on that job", not "show me all answers ever given".
///
/// A window rather than a third overlay panel: this is a reading surface with long lines and
/// a lot of them, it wants to be resized and left open next to the work, and the overlay is
/// for the two things that belong beside the figure.
struct RegistryView: View {
    @Bindable var model: RegistryModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Register")
        .onAppear { if !model.hasAnswered { model.reload() } }
    }

    // MARK: - Filter

    /// The three filters of the request, along the top where a person looks for them, and the
    /// reload beside them. Every one of them is also reachable from the keyboard: the pickers
    /// take focus in the tab order, and reload has Command-R.
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Projekt", selection: projectBinding) {
                Text("Alle Projekte").tag(String?.none)
                ForEach(model.knownProjects, id: \.self) { project in
                    Text((project as NSString).lastPathComponent).tag(String?.some(project))
                }
            }
            .frame(maxWidth: 220)

            Toggle("Nur mit Selbstantworten", isOn: selfAnswersBinding)
                .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Register wird geladen")
            }
            Button {
                model.reload()
            } label: {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Das Register neu vom Daemon holen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { model.filter.project },
            set: { model.filter.project = $0; model.reload() })
    }

    private var selfAnswersBinding: Binding<Bool> {
        Binding(
            get: { model.filter.withSelfAnswers },
            set: { model.filter.withSelfAnswers = $0; model.reload() })
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let notice = model.notice, model.isEmpty {
            ContentUnavailableView {
                Label("Nichts im Register", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(notice)
            }
        } else {
            List {
                ForEach(model.days) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            RegistryRow(entry: entry)
                        }
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    /// The day, its cost, and — where the figure does not rest on every run of that day — what
    /// it does rest on. `DESIGN.md` section Verhalten, "Kosten": "Ohne Quelle zeigt er
    /// unbekannt", and a partial figure has to say that it is one.
    private func dayHeader(_ day: RegistryDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(RegistryModel.readableDay(day.day))
                    .font(.headline)
                Spacer(minLength: 12)
                Text(day.cost.map { RegistryModel.readableCost($0.cost) } ?? "unbekannt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let footnote = day.cost.flatMap(RegistryModel.costFootnote) {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One run. Collapsed it is a line; opened it is everything the register kept about it.
private struct RegistryRow: View {
    let entry: RegistryEntry
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                detail
                if !entry.selfAnswers.isEmpty { selfAnswers }
                if !entry.openPoints.isEmpty { openPoints }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
            .textSelection(.enabled)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(RegistryModel.title(for: entry))
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.selfAnswers.isEmpty {
                        // The mark is a symbol plus a number, never colour alone: a count is
                        // what a person is looking for, and colour is not readable to
                        // everybody.
                        Label(
                            "\(entry.selfAnswers.count)",
                            systemImage: "bubble.left.and.text.bubble.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                "\(entry.selfAnswers.count) Selbstantworten")
                    }
                }
                Text(RegistryModel.subtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent("Kosten", value: RegistryModel.readableCost(entry.cost))
            if let path = entry.resultPath {
                LabeledContent("Ergebnisdatei", value: path)
            }
            LabeledContent(
                "Beginn", value: entry.startedAt.formatted(date: .omitted, time: .standard))
            if let ended = entry.endedAt {
                LabeledContent("Ende", value: ended.formatted(date: .omitted, time: .standard))
            }
        }
        .font(.callout)
    }

    private var selfAnswers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selbstantworten")
                .font(.callout.weight(.semibold))
            ForEach(Array(entry.selfAnswers.enumerated()), id: \.offset) { _, answer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(answer.question)
                        .font(.callout)
                    Text(answer.answer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // The source is the half that makes a self-answer reviewable: it says
                    // what the companion took the answer out of.
                    Label(answer.source, systemImage: "text.book.closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var openPoints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Offene Punkte")
                .font(.callout.weight(.semibold))
            ForEach(Array(entry.openPoints.enumerated()), id: \.offset) { _, point in
                Label(point, systemImage: "circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
