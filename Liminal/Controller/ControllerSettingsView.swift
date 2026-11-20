#if os(macOS)
import SwiftUI

struct ControllerSettingsView: View {
    @ObservedObject var controller: ControllerCoordinator

    var body: some View {
        ControlSection(title: "Push controller", systemImage: "slider.horizontal.3") {
            Toggle("Allow controller on this network", isOn: Binding(
                get: { controller.enabled }, set: { controller.setEnabled($0) }))
            TextField("Mac's private IPv4 address", text: $controller.address)
                .disabled(controller.enabled)
            TextField("Port", text: $controller.port)
                .disabled(controller.enabled)
            Text(controller.status)
                .font(.callout)
            Text("Use this Mac’s private LAN address to connect a Push. Loopback is available for local testing. Keep the listener on a trusted local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
            Text("Transport and status are available. Playing pads and changing channel mix or effects are not available in this build.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
            HStack {
                Button("Release controller notes") { controller.panic() }
                Button("Reset controller") { controller.reset() }
            }
        }
    }
}
#endif
