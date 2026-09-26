import Foundation
import CoreGraphics
import ScreenCaptureKit
import AVFoundation

/// Was wir über das Desk-View-Fenster wissen, ohne ScreenCaptureKit-Objekte
/// über Isolationsgrenzen zu reichen.
public struct DeskViewWindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    /// In Punkten, globale Bildschirmkoordinaten, Ursprung oben links.
    public let frame: CGRect
    public let backingScale: CGFloat
    public let title: String?

    public var pixelWidth: Int { Int((frame.width * backingScale).rounded()) }
    public var pixelHeight: Int { Int((frame.height * backingScale).rounded()) }

    /// Unter dieser Breite reicht die Auflösung nicht für eine Buchseite.
    public var isTooSmall: Bool { pixelWidth < DeskViewSource.minimumRecommendedPixelWidth }
}

public enum DeskViewStatus: Sendable, Equatable {
    case permissionMissing
    case notRunning
    case found(DeskViewWindowInfo)
}

public enum DeskViewError: Error, LocalizedError, Equatable {
    case permissionMissing
    case windowNotFound
    case captureProducedNoImage
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionMissing: return "Bildschirmaufnahme ist für diese App nicht freigegeben."
        case .windowNotFound: return "Kein Desk-View-Fenster gefunden."
        case .captureProducedNoImage: return "Die Aufnahme hat kein Bild geliefert."
        case .launchFailed(let reason): return "Desk View ließ sich nicht starten: \(reason)"
        }
    }
}

/// Bildschirmaufnahme-Freigabe. Die Freigabe hängt an der Bundle-ID der App.
public enum ScreenCapturePermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Zeigt den Systemdialog, wenn noch nie gefragt wurde. Liefert den neuen Stand.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Findet, startet und fotografiert das Fenster von Desk View.
public actor DeskViewSource {
    /// Bundle-ID von `/System/Library/CoreServices/Applications/Desk View.app`.
    public static let bundleIdentifier = "com.apple.DeskCam"
    public static let minimumRecommendedPixelWidth = 1600
    /// Kleinere Fenster sind Paletten oder Overlays, nicht die Hauptansicht.
    static let minimumCandidateSize: CGFloat = 200

    public init() {}

    public func status() async -> DeskViewStatus {
        guard ScreenCapturePermission.isGranted else { return .permissionMissing }
        guard let located = try? await locateWindow() else { return .notRunning }
        return .found(located.info)
    }

    /// Ein Vollbild-Screenshot des Fensters in Bildschirmpixeln.
    public func captureImage() async throws -> (image: CGImage, window: DeskViewWindowInfo) {
        guard ScreenCapturePermission.isGranted else { throw DeskViewError.permissionMissing }
        guard let located = try await locateWindow() else { throw DeskViewError.windowNotFound }

        let filter = SCContentFilter(desktopIndependentWindow: located.window)
        let configuration = SCScreenshotConfiguration()
        configuration.width = located.info.pixelWidth
        configuration.height = located.info.pixelHeight
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        configuration.dynamicRange = .sdr

        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        guard let image = output.sdrImage else { throw DeskViewError.captureProducedNoImage }
        return (image, located.info)
    }

    /// Startet Desk View oder holt es nach vorn. `windowFrame` in AppKit-Koordinaten
    /// (Ursprung unten links). Kehrt erst zurück, wenn die Einrichtung abgeschlossen ist.
    public func launch(windowFrame: CGRect) async throws {
        let configuration = AVCaptureDeskViewApplication.LaunchConfiguration()
        configuration.mainWindowFrame = windowFrame
        configuration.requiresSetUpModeCompletion = true
        do {
            try await AVCaptureDeskViewApplication().present(launchConfiguration: configuration)
        } catch {
            throw DeskViewError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: Fenstersuche

    private struct LocatedWindow {
        let window: SCWindow
        let info: DeskViewWindowInfo
    }

    private func locateWindow() async throws -> LocatedWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == Self.bundleIdentifier
                && window.windowLayer == 0
                && window.frame.width >= Self.minimumCandidateSize
                && window.frame.height >= Self.minimumCandidateSize
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }
        let scale = Self.backingScale(for: window.frame, displays: content.displays)
        let info = DeskViewWindowInfo(windowID: window.windowID, frame: window.frame, backingScale: scale, title: window.title)
        return LocatedWindow(window: window, info: info)
    }

    /// Verhältnis Pixel zu Punkten des Bildschirms, auf dem das Fenster liegt.
    static func backingScale(for frame: CGRect, displays: [SCDisplay]) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let display = displays.first { $0.frame.contains(center) } ?? displays.first
        guard let display, let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 else {
            return 2
        }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}
