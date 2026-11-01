import CarPlay
import UIKit
import os

/// Instantiated by the system from Info.plist when the phone connects to a car.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CarPlayInterface?
    /// Lives with the scene, not the interface, so a connection decides once even if it's announced twice.
    private var autoplay = CarAutoplay()

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] connected")
        MainActor.assumeIsolated {
            CarLog.shared.note("Car screen opened Truffle (app \(UIApplication.shared.applicationState.carLogName))")
            let interface = CarPlayInterface(interfaceController: interfaceController, environment: .shared)
            self.interface = interface
            interface.start()
            autoplay.carConnected(environment: .shared, showNowPlaying: interface.showNowPlaying)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] disconnected")
        MainActor.assumeIsolated {
            CarLog.shared.note("Car screen closed Truffle")
            interface?.stop()
            interface = nil
            autoplay.carDisconnected()
        }
    }
}
