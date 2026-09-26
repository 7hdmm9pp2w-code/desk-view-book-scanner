import AppKit
import Observation
import BookScannerKit

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
            let granted = await CameraSource.requestAccess()
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
        camera.onAutoTrigger = { [weak self] in
            Task { @MainActor in self?.capturePage() }
        }
        camera.onMotionState = { [weak self] state in
            Task { @MainActor in self?.motionState = state }
        }
    }
}
