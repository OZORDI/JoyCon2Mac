import Foundation
import IOKit
import SystemExtensions

final class DriverExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = DriverExtensionInstaller()

    private typealias StatusHandler = (String, Bool) -> Void

    private let driverIdentifier = "local.joycon2mac.driver"
    private var currentRequest: OSSystemExtensionRequest?
    private var statusHandlers: [StatusHandler] = []
    private var identicalReplacementWasCanceled = false

    private override init() {
        super.init()
    }

    func activate(status: @escaping (String, Bool) -> Void) {
        statusHandlers.append(status)

        guard currentRequest == nil else {
            status("Driver extension activation is already in progress...", false)
            return
        }

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: driverIdentifier,
            queue: .main
        )
        request.delegate = self
        currentRequest = request

        status("Submitting SystemExtensions activation request for \(driverIdentifier)...", false)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === currentRequest else { return }

        let detail: String
        switch result {
        case .completed:
            detail = "Driver extension activated."
        case .willCompleteAfterReboot:
            detail = "Driver extension accepted; macOS says a reboot is required before it becomes active."
        @unknown default:
            detail = "Driver extension activation finished with result \(result.rawValue)."
        }
        finish(detail, shouldRestartDaemon: result == .completed)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        guard request === currentRequest else { return }

        // Driver publication and replacement are asynchronous. Reconcile the
        // request error against IOKit for a short window before telling the UI
        // that the driver itself failed to load.
        reconcileFailure(error, attemptsRemaining: 10)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === currentRequest else { return }
        publish("Driver extension is waiting for approval in System Settings.", false)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard request === currentRequest else { return .cancel }

        if existing.bundleVersion == ext.bundleVersion,
           existing.bundleShortVersion == ext.bundleShortVersion {
            identicalReplacementWasCanceled = true
            publish("The bundled driver version is already installed.", false)
            return .cancel
        }

        identicalReplacementWasCanceled = false
        publish("Replacing existing DriverKit extension with the bundled build...", false)
        return .replace
    }

    private func reconcileFailure(_ error: Error, attemptsRemaining: Int) {
        guard currentRequest != nil else { return }

        if isDriverAlreadyLive() {
            let nsError = error as NSError
            let requestDidNotNeedActivation = identicalReplacementWasCanceled
                || isExpectedAlreadyLoadedError(nsError)

            if requestDidNotNeedActivation {
                finish("Driver extension is loaded.", shouldRestartDaemon: true)
            } else {
                finish(
                    "The existing driver is loaded, but the bundled update did not complete: \(error.localizedDescription)",
                    shouldRestartDaemon: false
                )
            }
            return
        }

        guard attemptsRemaining > 0 else {
            finish(
                "Driver extension activation failed: \(error.localizedDescription)",
                shouldRestartDaemon: false
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reconcileFailure(error, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func isExpectedAlreadyLoadedError(_ error: NSError) -> Bool {
        guard error.domain == "OSSystemExtensionErrorDomain" else { return false }
        return error.code == OSSystemExtensionError.extensionNotFound.rawValue
            || error.code == OSSystemExtensionError.requestCanceled.rawValue
            || error.code == OSSystemExtensionError.requestSuperseded.rawValue
    }

    private func publish(_ detail: String, _ shouldRestartDaemon: Bool) {
        statusHandlers.forEach { $0(detail, shouldRestartDaemon) }
    }

    private func finish(_ detail: String, shouldRestartDaemon: Bool) {
        let handlers = statusHandlers
        statusHandlers.removeAll()
        currentRequest = nil
        identicalReplacementWasCanceled = false
        for (index, handler) in handlers.enumerated() {
            handler(detail, shouldRestartDaemon && index == handlers.startIndex)
        }
    }

    // MARK: - IOKit probe
    //
    // Mirrors DriverKitClient's lookup: the dext publishes IOUserService with
    // IOUserClass=VirtualJoyConDriver, IOUserServerName=<bundle id>. If the
    // matching service exists in IOKit right now, the driver is loaded and
    // usable regardless of what the SystemExtensions request delegate reports.
    private func isDriverAlreadyLive() -> Bool {
        // IOServiceMatching on "VirtualJoyConDriver" gives us the specific
        // class, then we cross-check CFBundleIdentifier / IOUserServerName to
        // guard against unrelated services that happened to share the name.
        guard let matching = IOServiceMatching("VirtualJoyConDriver") else {
            return false
        }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS, iterator != 0 else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if isOurDriverService(service) {
                return true
            }
        }
        return false
    }

    private func isOurDriverService(_ service: io_service_t) -> Bool {
        return servicePropertyEquals(service, key: "CFBundleIdentifier", expected: driverIdentifier)
            && servicePropertyEquals(service, key: "IOUserServerName", expected: driverIdentifier)
    }

    private func servicePropertyEquals(_ service: io_service_t,
                                       key: String,
                                       expected: String) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(service,
                                                        key as CFString,
                                                        kCFAllocatorDefault,
                                                        0) else {
            return false
        }
        let value = raw.takeRetainedValue()
        guard let str = value as? String else { return false }
        return str == expected
    }
}
