import SwiftUI

/// The sidebar's Mac menu: shows the current device scope and opens a searchable list of Macs.
///
/// As in the page, the list drops down 6 pt under the picker at the picker's width, without an arrow, over the
/// rows below (the sidebar draws the picker above them). A click outside the picker and the list, or Escape,
/// closes it.
struct SidebarMacPicker: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let current = SidebarMacOption.current(in: model.devices)
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(current.color)
                    .frame(width: 8, height: 8)
                Text(current.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(current.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkGlass)
                    .lineLimit(1)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Theme.inkGlass)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .background(isHovering || isPresented ? Theme.fill2 : Theme.fill, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityLabel(tr("Mac", "Sidebar"))
        .accessibilityValue(current.label)
        .overlay(alignment: .top) {
            if isPresented {
                VStack(spacing: 6) {
                    // The picker's own area, so a click on it toggles the list instead of closing it first.
                    Color.clear
                        .frame(height: Self.height)
                        .allowsHitTesting(false)
                    SidebarMacMenu { isPresented = false }
                }
                .background {
                    // A click outside the picker and the list, or Escape, closes it.
                    EventMonitor(
                        onKeyDown: { event in
                            guard event.keyCode == EventMonitor.escapeKey else { return false }
                            isPresented = false
                            return true
                        },
                        onMouseDown: { inside in
                            if !inside { isPresented = false }
                        }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                // Laid out in the picker's frame and drawn below it.
                .frame(height: Self.height, alignment: .top)
            }
        }
    }

    static let height: CGFloat = 30
}

/// The open Mac menu: a "Find a Mac" field, "All Macs" and every Mac whose name matches, on the page's menu
/// glass (`max(.88, glassA)`, radius 10, a hairline and a soft shadow).
private struct SidebarMacMenu: View {
    @Environment(AppModel.self) private var model
    var dismiss: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let options = SidebarMacOption.options(in: model.devices, matching: query)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(Theme.ink3, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                TextField(tr("Find a Mac", "Sidebar"), text: $query, prompt: Text(tr("Find a Mac", "Sidebar")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = options.first(where: { $0.scope != .all }) ?? options.first { pick(first) }
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.fill, in: .rect(cornerRadius: 6, style: .continuous))
            .padding(.bottom, 4)
            ForEach(options) { option in
                SidebarMacMenuRow(option: option, isSelected: option.scope == model.devices.scope) {
                    pick(option)
                }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(GlassSurface.menu.tint(preference: model.preferences.glass), in: Self.shape)
        .glassEffect(.regular, in: Self.shape)
        .overlay { Self.shape.strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: 15, y: 10)
        .onAppear { searchFocused = true }
    }

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    private func pick(_ option: SidebarMacOption) {
        if model.devices.scope != option.scope {
            model.devices.scope = option.scope
            model.nav.selectedRequest = nil
        }
        dismiss()
    }
}

private struct SidebarMacMenuRow: View {
    var option: SidebarMacOption
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                    .opacity(isSelected ? 1 : 0)
                Circle()
                    .fill(option.color)
                    .frame(width: 8, height: 8)
                Text(option.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(option.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(isHovering ? Theme.accentTint : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One entry of the Mac menu.
struct SidebarMacOption: Identifiable, Equatable {
    var scope: DeviceScope
    var label: String
    /// "This Mac" / "Online" / "Offline", or "3 Macs" for the current "All Macs" label.
    var detail: String
    var color: Color

    var id: String {
        switch scope {
        case .all: "all"
        case .device(let id): id.uuidString
        }
    }

    /// The label of the closed menu for the current scope.
    @MainActor
    static func current(in state: DeviceState) -> SidebarMacOption {
        if case .device(let id) = state.scope, let device = state.device(id) {
            return option(for: device, in: state)
        }
        return SidebarMacOption(
            scope: .all,
            label: tr("All Macs", "Sidebar"),
            detail: trn("%lld Mac", "%lld Macs", state.devices.count, "Sidebar"),
            color: Theme.ink3
        )
    }

    /// "All Macs", whatever the query, followed by every Mac whose name contains `query`.
    @MainActor
    static func options(in state: DeviceState, matching query: String) -> [SidebarMacOption] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = SidebarMacOption(scope: .all, label: tr("All Macs", "Sidebar"), detail: "", color: Theme.ink3)
        let devices = sortedDevices(state)
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .map { option(for: $0, in: state) }
        return [all] + devices
    }

    /// This Mac first, then the others by name.
    @MainActor
    static func sortedDevices(_ state: DeviceState) -> [Device] {
        state.devices.sorted { a, b in
            if (a.id == state.thisDeviceID) != (b.id == state.thisDeviceID) { return a.id == state.thisDeviceID }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @MainActor
    private static func option(for device: Device, in state: DeviceState) -> SidebarMacOption {
        let detail: String
        if device.id == state.thisDeviceID {
            detail = tr("This Mac", "Sidebar")
        } else {
            detail = device.isOnline ? tr("Online", "Sidebar") : tr("Offline", "Sidebar")
        }
        return SidebarMacOption(scope: .device(device.id), label: device.name, detail: detail, color: Theme.deviceColor(hue: device.hue))
    }
}
