import AppKit
import SwiftUI

/// The request table shared by Live and History: Time, App · Process, Host, Remote IP, Policy, Size.
///
/// Table cells are hosted outside the SwiftUI environment chain, so they receive the model explicitly instead
/// of reading it from `@Environment`.
struct RequestsTable: View {
    enum TimeStyle {
        /// `14:32:27.130`
        case clock
        /// `Oct 24 14:21:25.017`
        case dayClock
    }

    var model: AppModel
    var rows: [RequestRecord]
    /// The selected row; nil when rows cannot be selected (History, whose rows open no inspector).
    var selection: Binding<RequestKey?>?
    var timeStyle: TimeStyle
    /// Reference time for the fresh-row background; nil disables it (History).
    var now: Date?
    /// The BY IP and NEW badges after the host, which the design shows in the live table only.
    var showsHostBadges = true
    /// Called when the last row comes into view (History loads its next page).
    var onReachEnd: (() -> Void)?

    /// Fits History's longest time, `10月24日 23:59:59.999` in Chinese, in 11 pt SF Mono with the cell's inset.
    static let historyTimeWidth: CGFloat = 146
    /// Fits the widest IPv4 address (`255.255.255.255`, about 102 pt in 11 pt SF Mono) with the cell's inset.
    static let remoteIPWidth: CGFloat = 108
    /// The App · Process column never gets narrower than the tile and an app name like `Brave Browser` with
    /// the start of its process (`Brave Browser › …`).
    static let appMinWidth: CGFloat = 130
    /// The Policy column never gets narrower than the group plus enough of the final policy to tell nodes
    /// apart (`AI › …kNerd-Hysteria2`).
    static let policyMinWidth: CGFloat = 140

    var body: some View {
        // How a table shares width out depends on how it was built. A table that grows with its window widens
        // every resizable column up to its maximum, but one built while its column is still changing size
        // (opening the page, switching between Live and History, the inspector opening) keeps every column
        // that has a maximum at its minimum and gives the slack to the columns without one, in equal shares on
        // top of their ideal widths. So Time, Remote IP and Size are fixed to their text, Policy has a readable
        // minimum and stops growing where long policies end, and App · Process and Host have no maximum, so
        // whatever is left is always shared between the app names and the hosts, Host keeping the wider share.
        // The minimums add up to about the content column of the smallest window; below that the table
        // scrolls horizontally.
        Group {
            if let selection {
                Table(rows, selection: selection) { columns }
            } else {
                Table(rows) { columns }
            }
        }
        .alternatingRowBackgrounds()
        // A table reports the sum of its column widths as its minimum, which would push the split view past the
        // window once the inspector opens; below that width it scrolls horizontally instead.
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    @TableColumnBuilder<RequestRecord, Never>
    private var columns: some TableColumnContent<RequestRecord, Never> {
        TableColumn(Self.header(tr("Time", "Requests"))) { record in
            RequestsTimeCell(date: record.startedAt, style: timeStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    if now != nil {
                        RequestsRowTint(key: record.key, isFresh: isFresh(record), isSelected: record.key == selectedKey)
                    }
                }
                .onAppear {
                    if let onReachEnd, record.key == rows.last?.key { onReachEnd() }
                }
        }
        .width(timeStyle == .clock ? 86 : Self.historyTimeWidth)

        TableColumn(Self.header(tr("App · Process", "Requests"))) { record in
            RequestsAppCell(model: model, record: record)
        }
        .width(min: Self.appMinWidth, ideal: 180)

        TableColumn(Self.header(tr("Host", "Requests"))) { record in
            RequestsHostCell(record: record, showsBadges: showsHostBadges)
        }
        .width(min: 140, ideal: 220)

        TableColumn(Self.header(tr("Remote IP", "Requests"))) { record in
            RequestsRemoteIPCell(remoteIP: record.remoteIP)
        }
        .width(Self.remoteIPWidth)

        TableColumn(Self.header(tr("Policy", "Requests"))) { record in
            // The shared chip: a truncated policy keeps its group and the end of the final policy.
            PolicyChip(policyPath: record.policyPath, maxWidth: .infinity)
        }
        .width(min: Self.policyMinWidth, ideal: 170, max: 200)

        TableColumn(Self.header(tr("Size", "Requests"))) { record in
            RequestsSizeCell(record: record)
        }
        .width(64)
        .alignment(.trailing)
    }

    private var selectedKey: RequestKey? { selection?.wrappedValue }

    /// Fresh rows get the arrival tint, except the selected one, which keeps the system selection.
    private func isFresh(_ record: RequestRecord) -> Bool {
        guard let now, record.key != selectedKey else { return false }
        return RequestsPresentation.isFresh(record, now: now)
    }

    /// The design's header labels: 11 pt semibold in the secondary ink.
    private static func header(_ title: String) -> Text {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.ink2)
    }
}

/// Monospaced start time.
struct RequestsTimeCell: View {
    var date: Date
    var style: RequestsTable.TimeStyle

    var body: some View {
        Text(Self.label(date, style: style, locale: Localizer.shared.locale))
            .font(Theme.mono(11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// `14:32:27.130` in the live table, `Oct 24 14:21:25.017` (`10月24日 14:21:25.017`) in History.
    static func label(_ date: Date, style: RequestsTable.TimeStyle, locale: Locale) -> String {
        style == .clock ? Fmt.clock(date) : Fmt.monthDay(date, locale: locale) + " " + Fmt.clock(date)
    }
}

/// `[MBP] ▣ Cursor › node`: device badge (several Macs), app tile, app name and the sending process.
struct RequestsAppCell: View {
    var model: AppModel
    var record: RequestRecord

    var body: some View {
        let identity = model.requestsIdentity(for: record)
        let process = RequestsPresentation.processName(of: record)
        let suffix = process.map { $0 != identity.name ? " › " + $0 : "" } ?? ""
        HStack(spacing: 6) {
            if model.devices.showsDeviceBadges {
                DeviceBadge(shortName: model.devices.shortName(record.deviceID), hue: model.devices.hue(record.deviceID))
            }
            AppTile(identity: identity, size: 16)
            Text("\(Text(identity.name).fontWeight(.medium))\(Text(suffix).foregroundStyle(.secondary))")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(record.processPath ?? process ?? identity.name)
    }
}

/// `CONNECT  api2.cursor.sh  BY IP  NEW`
struct RequestsHostCell: View {
    var record: RequestRecord
    var showsBadges = true

    var body: some View {
        HStack(spacing: 6) {
            Text(record.method.uppercased())
                .font(Theme.mono(9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
            Text(record.host)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if showsBadges, record.isIPLiteral {
                TagBadge(text: tr("BY IP", "Requests"), style: .neutral)
            }
            if showsBadges, record.isNew {
                TagBadge(text: tr("NEW", "Requests"), style: .new)
            }
        }
        .help(record.url ?? record.host)
    }
}

/// Byte count, or "failed" in red for a request Surge failed or rejected.
struct RequestsSizeCell: View {
    var record: RequestRecord

    var body: some View {
        Group {
            switch record.state {
            case .failed, .rejected:
                Text(tr("failed", "Requests")).foregroundStyle(Theme.failed)
            case .active, .completed:
                Text(Fmt.bytes(record.totalBytes)).foregroundStyle(.tertiary)
            }
        }
        .font(Theme.mono(11))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Monospaced remote IP. Every IPv4 address fits the column; a longer IPv6 address is shortened in the middle
/// and shown in full on hover.
struct RequestsRemoteIPCell: View {
    var remoteIP: String?

    var body: some View {
        Text(remoteIP ?? "—")
            .font(Theme.mono(11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(remoteIP ?? "")
    }
}

/// Writes plain text to the general pasteboard.
enum RequestsPasteboard {
    @MainActor
    static func copy(_ string: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(string, forType: .string)
    }
}
