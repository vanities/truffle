import CarPlay
import UIKit
import os

/// Instantiated by the system from Info.plist when the phone connects to a car.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] connected")
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] disconnected")
    }
}
