// Prüft, welche Video- und Fotogrößen ein iPhone über Continuity Camera liefert,
// und nimmt testweise ein Foto in größtmöglicher Auflösung auf.
// Aufruf (kompiliert, der Interpreter stürzt an AVCapturePhotoOutput ab):
//   swiftc -O scripts/probe_continuity_photo.swift -o /tmp/probe && /tmp/probe
import AVFoundation
import Foundation

final class Delegate: NSObject, AVCapturePhotoCaptureDelegate {
    var finished = false
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { print("  Fehler beim Foto: \(error.localizedDescription)") }
        else {
            let d = photo.resolvedSettings.photoDimensions
            print("  Foto erhalten: \(d.width) × \(d.height)")
            if let data = photo.fileDataRepresentation() {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("continuity_probe.heic")
                try? data.write(to: url)
                print("  gespeichert: \(url.path) (\(data.count / 1024) KB)")
            }
        }
        finished = true
    }
}

func dims(_ f: AVCaptureDevice.Format) -> String {
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    return "\(d.width) × \(d.height) @ \(Int(fps)) fps"
}

let sem = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .video) { granted = $0; sem.signal() }
sem.wait()
guard granted else { print("Kein Kamerazugriff."); exit(1) }

let devices = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.continuityCamera, .deskViewCamera, .external, .builtInWideAngleCamera],
    mediaType: .video, position: .unspecified).devices
print("Gefundene Kameras:")
for d in devices { print("- \(d.localizedName) [\(d.deviceType.rawValue)] continuity=\(d.isContinuityCamera)") }

guard let phone = devices.first(where: { $0.isContinuityCamera && $0.deviceType != .deskViewCamera }) else {
    print("\nKein iPhone als Continuity Camera gefunden. iPhone entsperren, in die Nähe legen, WLAN+Bluetooth an.")
    exit(2)
}
print("\niPhone: \(phone.localizedName)")
print("Formate (Video → max. Fotogrößen):")
for f in phone.formats {
    let photos = f.supportedMaxPhotoDimensions.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
    print("  \(dims(f))  →  Foto: \(photos.isEmpty ? "–" : photos)")
}

let session = AVCaptureSession()
session.beginConfiguration()
let input = try AVCaptureDeviceInput(device: phone)
session.addInput(input)
let output = AVCapturePhotoOutput()
guard session.canAddOutput(output) else { print("Foto-Ausgabe nicht möglich."); exit(3) }
session.addOutput(output)
// Manche Fotogrößen meldet das Gerät erst, wenn eine Foto-Ausgabe hängt.
print("\nNach Anhängen der Foto-Ausgabe:")
for f in phone.formats {
    let photos = f.supportedMaxPhotoDimensions.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
    print("  \(dims(f))  →  Foto: \(photos.isEmpty ? "–" : photos)")
}
// Format mit der größten Fotogröße wählen.
let best = phone.formats.max { a, b in
    let pa = a.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
    let pb = b.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
    return pa < pb
}
if let best {
    try phone.lockForConfiguration()
    phone.activeFormat = best
    phone.unlockForConfiguration()
    print("\nGewähltes Format: \(dims(best))")
}
let maxDims = phone.activeFormat.supportedMaxPhotoDimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
if let maxDims { output.maxPhotoDimensions = maxDims }
session.commitConfiguration()
session.startRunning()
Thread.sleep(forTimeInterval: 3)

// maxPhotoDimensions bleibt in den Einstellungen offen: Ein expliziter Wert wirft
// beim iPhone eine NSException, selbst wenn er aus supportedMaxPhotoDimensions stammt.
let settings = AVCapturePhotoSettings()
let delegate = Delegate()
print("Nehme Foto auf (laut Format höchstens: \(maxDims.map { "\($0.width)×\($0.height)" } ?? "Standard")) …")
output.capturePhoto(with: settings, delegate: delegate)
// Den Hauptthread nicht blockieren: Der Rückruf kann über ihn laufen.
let deadline = Date().addingTimeInterval(20)
while !delegate.finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
if !delegate.finished { print("  Zeitüberschreitung beim Foto.") }
session.stopRunning()
