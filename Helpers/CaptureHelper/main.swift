import AppKit
import ImageIO

// One-shot capture helper. The host launches it through LaunchServices, which makes it its own responsible
// process: Screen Recording is granted to this helper alone, never to the host that spawns plugins
// (PRD §3.5, plan §12). It runs the system's interactive selection and leaves the result for the host.
//
// Usage: RuyioCaptureHelper --output <directory>
// Writes <directory>/capture.png and <directory>/result.json, then exits.

struct HelperResult: Encodable {
    var status: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var scale: Double?
}

func finish(_ result: HelperResult, in directory: URL) -> Never {
    if let data = try? JSONEncoder().encode(result) {
        try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
    exit(0)
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--output"), flag + 1 < arguments.count else { exit(64) }
let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)

// An application run loop lets LaunchServices see the launch complete; the work runs off the main thread.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
DispatchQueue.global(qos: .userInitiated).async {
    guard CGPreflightScreenCaptureAccess() else {
        // Lists the helper under Screen Recording in System Settings; the host explains what to do.
        _ = CGRequestScreenCaptureAccess()
        finish(HelperResult(status: "permissionRequired"), in: directory)
    }
    let output = directory.appendingPathComponent("capture.png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -i interactive selection (space toggles window mode), -o no window shadow, -x no sound.
    process.arguments = ["-i", "-o", "-x", "-t", "png", output.path]
    do {
        try process.run()
        // Ends a selection left open before the host gives up on it (110 s) and stops this helper: screencapture
        // would otherwise outlive it, leaving its crosshair on screen.
        DispatchQueue.global().asyncAfter(deadline: .now() + 105) { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
    } catch {
        finish(HelperResult(status: "failed"), in: directory)
    }
    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
        // Escape or a click without a selection leaves no file.
        finish(HelperResult(status: "cancelled"), in: directory)
    }
    // screencapture records the display density as DPI: 144 on a 2x screen.
    let dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 72
    let scale = min(4, max(1, (dpi / 72).rounded()))
    finish(HelperResult(status: "captured", pixelWidth: width, pixelHeight: height, scale: scale), in: directory)
}
application.run()
