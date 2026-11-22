import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    private var statusColor: Color {
        switch state.status {
        case .matched: return Theme.good(scheme)
        case .mismatch: return Theme.warn(scheme)
        case .idle, .switching: return .secondary
        }
    }

    private var isNeutral: Bool {
        state.status == .idle || state.status == .switching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            signalPath
            if let note = state.mismatchNote {
                notice(note, symbol: "info.circle.fill")
            }
            if let problem = state.problem {
                notice(problem, symbol: "exclamationmark.triangle.fill")
            }
            if let playing = state.activeNowPlaying {
                nowPlaying(playing)
            }
            sourceList
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconArt(small: true)
                .frame(width: 22, height: 22)
            Text("BitMatch")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(state.statusLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(statusColor.opacity(0.14)))
        }
    }

    // MARK: Source -> output

    private var signalPath: some View {
        HStack(spacing: 6) {
            formatCard(
                label: state.sourceLabel,
                rate: state.sourceRate,
                detail: state.sourceDetail,
                caption: state.sourceCaption
            )
            connector
            formatCard(
                label: L("Output", "출력"),
                rate: state.deviceRate,
                detail: state.deviceBits.map { "\($0)-bit" } ?? "—",
                caption: state.deviceName ?? L("No output device", "출력 장치 없음")
            )
        }
    }

    private var connector: some View {
        let symbol: String
        switch state.status {
        case .matched: symbol = "equal"
        case .mismatch: symbol = "arrow.triangle.2.circlepath"
        case .idle, .switching: symbol = "arrow.right"
        }
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isNeutral ? Color.secondary : Theme.onStatus(scheme))
            .frame(width: 22, height: 22)
            .background(Circle().fill(isNeutral ? Color.primary.opacity(0.08) : statusColor))
    }

    private func formatCard(label: String, rate: Double?, detail: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(label)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rate.map(rateNumber) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if rate != nil {
                    Text("kHz")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            Text(detail)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .padding(.top, 1)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    // MARK: Notices

    private func notice(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.warn(scheme))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.warn(scheme).opacity(0.12)))
    }

    // MARK: Now playing

    private func nowPlaying(_ info: NowPlaying) -> some View {
        HStack(spacing: 9) {
            Image(systemName: info.isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let artist = info.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sources

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(L("Follow these apps", "따라갈 앱"))
                .padding(.bottom, 3)
            ForEach(state.sources) { source in
                sourceRow(source)
                if state.expandedSourceID == source.id {
                    rulePicker(for: source)
                }
            }
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        let isActive = source.id == state.activeSourceID
        let isOpen = source.id == state.expandedSourceID
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? (isNeutral ? Color.primary.opacity(0.55) : statusColor) : Color.primary.opacity(0.16))
                .frame(width: 6, height: 6)
            Text(source.name)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(rowLabel(for: source))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { state.expandedSourceID = isOpen ? nil : source.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// What a source's row says about its rule. For apps other than Apple Music, "auto" names
    /// the rate it falls back on when the app reports nothing.
    private func rowLabel(for source: Source) -> String {
        let rule = state.rule(for: source)
        guard rule == .auto, source.kind != .music else { return ruleLabel(rule, long: true) }
        let auto = L("Auto", "자동")
        return source.presetRate.map { "\(auto) · \(formatRate($0))" } ?? auto
    }

    private func ruleLabel(_ rule: SourceRule, long: Bool) -> String {
        switch rule {
        case .auto: return long ? L("Each track's own format", "곡마다 자동") : L("Auto", "자동")
        case .ignore: return long ? L("Don't switch", "전환 안 함") : L("Off", "끔")
        case .fixed(let rate): return long ? formatRate(rate) : rateNumber(rate)
        }
    }

    /// The rules a source can be given. "Auto" is offered wherever the app is able to report
    /// what it is playing, which Spotify never does.
    private func ruleChoices(for source: Source) -> [SourceRule] {
        if source.kind == .music { return [.auto, .ignore] }
        let rates = state.deviceRates.isEmpty ? [44100, 48000, 88200, 96000, 176400, 192000] : state.deviceRates
        return (source.canReportFormat ? [.auto] : []) + [.ignore] + rates.map(SourceRule.fixed)
    }

    private func rulePicker(for source: Source) -> some View {
        let current = state.rule(for: source)
        let rows = chipRows(ruleChoices(for: source))
        return VStack(spacing: 5) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        ruleChip(rows[row][column], selected: rows[row][column] == current, source: source)
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 6)
    }

    /// Fixed-width rows; the last row is padded with nils so chips keep the same width.
    private func chipRows(_ rules: [SourceRule], perRow: Int = 6) -> [[SourceRule?]] {
        stride(from: 0, to: rules.count, by: perRow).map { start in
            let slice = rules[start..<min(start + perRow, rules.count)].map(Optional.some)
            return slice + Array(repeating: nil, count: perRow - slice.count)
        }
    }

    private func ruleChip(_ rule: SourceRule?, selected: Bool, source: Source) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Text(rule.map { ruleLabel($0, long: false) } ?? " ")
            .font(.system(size: 11, weight: selected ? .bold : .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(selected ? Theme.onStatus(scheme) : Color.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(shape.fill(selected ? Theme.good(scheme) : Color.primary.opacity(rule == nil ? 0 : 0.06)))
            .contentShape(Rectangle())
            .onTapGesture {
                if let rule { state.setRule(rule, for: source) }
            }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHidden(rule == nil)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 11) {
            Toggle(L("Switch automatically", "자동 전환"), isOn: $state.autoSwitch)
            Toggle(L("Match bit depth too", "비트뎁스도 맞추기"), isOn: $state.matchBitDepth)
                .disabled(!state.autoSwitch)
                .opacity(state.autoSwitch ? 1 : 0.45)
            Toggle(L("Open at login", "로그인 시 실행"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            HStack {
                Text(L("Menu bar", "메뉴 막대"))
                Spacer(minLength: 12)
                SegmentedPicker(
                    options: [
                        (AppState.MenuBarStyle.iconAndRate, L("Icon + rate", "아이콘+숫자")),
                        (.rateOnly, L("Rate", "숫자")),
                        (.iconOnly, L("Icon", "아이콘")),
                    ],
                    selection: $state.menuBarStyle
                )
                .frame(width: 200)
            }
        }
        .font(.system(size: 12.5))
        .toggleStyle(PillToggleStyle(tint: Theme.good(scheme)))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("v\(appVersion)")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("GitHub") {
                if let url = URL(string: "https://github.com/qkdeoddl12/BitMatch") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L("Quit", "종료")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 11.5))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Controls

/// A switch drawn in SwiftUI so it looks the same everywhere it is rendered.
struct PillToggleStyle: ToggleStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? tint : Color.primary.opacity(0.16))
                .frame(width: 32, height: 19)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? L("On", "켬") : L("Off", "끔"))
    }
}

struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Text(option.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option.value }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}
