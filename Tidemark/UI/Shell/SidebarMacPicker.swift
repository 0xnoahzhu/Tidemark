import SwiftUI

/// The sidebar's Mac menu: shows the current device scope and opens a searchable list of Macs.
///
/// It sits at the top of the sidebar like a toolbar platter: a Liquid Glass capsule whose glass follows the
/// Settings › General › Liquid Glass preference (clear at one end, tinted at the other).
struct SidebarMacPicker: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let current = SidebarMacOption.current(in: model.devices)
        let style = SidebarGlassStyle(preference: model.preferences.glass)
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.inkGlass)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(isHovering || isPresented ? Theme.fill : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .glassEffect(style.glass.interactive(), in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SidebarMacMenu(model: model) { isPresented = false }
        }
        .accessibilityLabel(tr("Mac", "Sidebar"))
        .accessibilityValue(current.label)
        .help(tr("Show data from one Mac or from all of them", "Sidebar"))
    }
}

/// Contents of the Mac menu popover: a "Find a Mac" field, "All Macs" and every Mac in the database.
/// The popover is hosted in its own window, so the model is passed in.
private struct SidebarMacMenu: View {
    var model: AppModel
    var dismiss: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let options = SidebarMacOption.options(in: model.devices, matching: query)
        VStack(alignment: .leading, spacing: 1) {
            TextField(tr("Find a Mac", "Sidebar"), text: $query, prompt: Text(tr("Find a Mac", "Sidebar")))
                .textFieldStyle(.bordered)
                .textInputBorderShape(.capsule)
                .focused($searchFocused)
                .padding(.bottom, 5)
                .onSubmit {
                    if let first = options.first(where: { $0.scope != .all }) ?? options.first { pick(first) }
                }
            ForEach(options) { option in
                SidebarMacMenuRow(option: option, isSelected: option.scope == model.devices.scope) {
                    pick(option)
                }
            }
            if options.isEmpty {
                Text(tr("No Macs match", "Sidebar"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
        }
        .padding(6)
        .frame(width: 236)
        .onAppear { searchFocused = true }
    }

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
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
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

    /// "All Macs" followed by every Mac whose name contains `query`.
    @MainActor
    static func options(in state: DeviceState, matching query: String) -> [SidebarMacOption] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = SidebarMacOption(scope: .all, label: tr("All Macs", "Sidebar"), detail: "", color: Theme.ink3)
        let devices = sortedDevices(state)
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .map { option(for: $0, in: state) }
        let showAll = needle.isEmpty || all.label.lowercased().contains(needle)
        return (showAll ? [all] : []) + devices
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
