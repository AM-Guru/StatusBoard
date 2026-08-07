#if canImport(HomeKit) && canImport(UIKit) && !os(watchOS) && !os(macOS)
import SwiftUI
import HomeKit
import UIKit

/// A live HomeKit camera, embedded in a panel.
///
/// `HMCameraView` is the only public way to see a HomeKit camera — there is
/// no API that hands over frames — so this is a real UIKit view rather than
/// an image in a snapshot. Which in turn is why the panel is exempt from the
/// fetch loop: there is nothing to store, and the stream has to be started
/// and stopped with the view's life rather than on a timer.
struct HomeKitCameraStream: UIViewRepresentable {
    /// The accessory's `uniqueIdentifier`. Nil shows the first camera found,
    /// so a newly added panel is not blank while someone picks one.
    let accessoryID: String?
    let homeName: String?

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        context.coordinator.attach(to: view, accessoryID: accessoryID, homeName: homeName)
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {
        context.coordinator.attach(to: view, accessoryID: accessoryID, homeName: homeName)
    }

    static func dismantleUIView(_ view: HMCameraView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the stream. A camera stream is a real network session to the
    /// accessory, so it is started once and torn down when the panel goes
    /// away — leaving it running is what drains an Apple TV's battery-powered
    /// doorbell.
    @MainActor
    final class Coordinator: NSObject, HMCameraStreamControlDelegate {
        private weak var view: HMCameraView?
        private var control: HMCameraStreamControl?
        private var currentID: String?

        func attach(to view: HMCameraView, accessoryID: String?, homeName: String?) {
            self.view = view
            let key = accessoryID ?? "first"
            guard key != currentID else { return }
            stop()
            currentID = key
            Task { await start(accessoryID: accessoryID, homeName: homeName) }
        }

        private func start(accessoryID: String?, homeName: String?) async {
            guard case .granted = await HomeKitBridge.shared.authorization() else { return }
            guard let profile = await HomeKitBridge.shared.cameraProfile(accessoryID: accessoryID,
                                                                        homeName: homeName),
                  let control = profile.streamControl else { return }
            self.control = control
            control.delegate = self
            control.startStream()
        }

        func stop() {
            control?.stopStream()
            control?.delegate = nil
            control = nil
            view?.cameraSource = nil
        }

        nonisolated func cameraStreamControlDidStartStream(_ control: HMCameraStreamControl) {
            Task { @MainActor in
                self.view?.cameraSource = control.cameraStream
            }
        }

        nonisolated func cameraStreamControl(_ control: HMCameraStreamControl,
                                             didStopStreamWithError error: Error?) {
            Task { @MainActor in
                self.view?.cameraSource = nil
            }
        }
    }
}

extension HomeKitBridge {
    /// The camera profile a panel is pointed at, or the first camera in the
    /// home when nothing has been chosen yet.
    func cameraProfile(accessoryID: String?, homeName: String?) async -> HMCameraProfile? {
        guard case .granted = await authorization() else { return nil }
        let accessories = await cameraAccessories(homeName: homeName)
        if let accessoryID, !accessoryID.isEmpty,
           let match = accessories.first(where: { $0.uniqueIdentifier.uuidString == accessoryID }) {
            return match.cameraProfiles?.first
        }
        return accessories.first?.cameraProfiles?.first
    }
}
#endif
