import AppKit
import AVFoundation
import Observation
import OSLog
import BookScannerKit

private let cameraLog = Logger(subsystem: "org.crushkilldestroy.DeskViewBookScanner", category: "Kamera")

// MARK: - Kamera-Quelle

extension AppModel {
    static let cameraDeviceDefaultsKey = "cameraDeviceID"
    static let autoTriggerDefaultsKey = "autoTrigger"
    static let cameraSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    var cameraAuthorized: Bool { CameraSource.isAuthorized }

    var canCapture: Bool { cameraRunning && !isCapturing && exportStatus == nil && !sessionArchived }

    var selectedCamera: CameraDeviceInfo? {
        cameraDevices.first { $0.id == selectedCameraID }
    }

    func refreshCameraDevices() {
        cameraDevices = CameraSource.availableDevices()
        if selectedCameraID == nil || !cameraDevices.contains(where: { $0.id == selectedCameraID }) {
            // Vorzugsweise die Kamera mit den meisten Pixeln, Desk View nur als Rückfall.
            selectedCameraID = (cameraDevices.first { $0.kind != .deskView } ?? cameraDevices.first)?.id
        }
    }

    func requestCameraAccess() {
        Task {
            cameraLog.notice("Freigabe per Knopf, Status vorher \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            let granted = await CameraSource.requestAccess()
            cameraLog.notice("Freigabe per Knopf, Ergebnis \(granted)")
            if granted {
                refreshCameraDevices()
                if captureSource == .camera { await startCamera() }
            } else {
                NSWorkspace.shared.open(Self.cameraSettingsURL)
            }
        }
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        UserDefaults.standard.set(id, forKey: Self.cameraDeviceDefaultsKey)
        if captureSource == .camera { Task { await startCamera() } }
    }

    /// Startet die gewählte Kamera; ohne Freigabe oder Gerät bleibt sie still.
    func startCamera() async {
        cameraLog.notice("startCamera: Status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (0 unbestimmt, 1 eingeschränkt, 2 verweigert, 3 erlaubt), Gerät \(self.selectedCameraID ?? "-", privacy: .public)")
        if CameraSource.isUndetermined {
            let granted = await CameraSource.requestAccess()
            cameraLog.notice("Freigabe angefragt, Ergebnis \(granted)")
        }
        guard cameraAuthorized else { cameraRunning = false; return }
        if cameraDevices.isEmpty { refreshCameraDevices() }
        guard let id = selectedCameraID else { cameraRunning = false; return }
        do {
            try await camera.start(deviceID: id)
            cameraRunning = true
            camera.setAutoTrigger(autoTrigger)
            lastError = nil
        } catch {
            cameraRunning = false
            lastError = error.localizedDescription
        }
    }

    func stopCamera() {
        camera.stop()
        cameraRunning = false
        motionState = .idle
    }

    func setAutoTrigger(_ on: Bool) {
        autoTrigger = on
        UserDefaults.standard.set(on, forKey: Self.autoTriggerDefaultsKey)
        camera.setAutoTrigger(on)
        if !on { motionState = .idle }
    }

    /// Verbindet die Rückrufe der Kamera-Queue mit dem Main-Actor.
    func wireCameraCallbacks() {
        // Mitschnitt zum Einstellen des Auslösers, nur per `defaults write … AusloeserMitschnitt <Ordner>`.
        if let path = UserDefaults.standard.string(forKey: "AusloeserMitschnitt"), !path.isEmpty {
            camera.recordingDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
        camera.onAutoTrigger = { [weak self] in
            Task { @MainActor in self?.capturePage() }
        }
        camera.onMotionState = { [weak self] state in
            Task { @MainActor in
                self?.motionState = state
                if state != .idle { self?.skippedKnownPage = false }
            }
        }
        camera.onSkippedKnownPage = { [weak self] in
            Task { @MainActor in self?.skippedKnownPage = true }
        }
    }
}
