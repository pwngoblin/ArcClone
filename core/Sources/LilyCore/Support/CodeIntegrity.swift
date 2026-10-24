import Foundation
import Security

/// Launch-time check of the app's own code signature. Gatekeeper validates a download once; this
/// catches later edits to the installed app, such as a modified injection script or a swapped
/// binary, before any of it runs.
enum CodeIntegrity {
    /// Returns a description of the problem, or nil when the signature and sealed resources are intact.
    static func verify(bundleAt url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { check(url) }.value
    }

    private static func check(_ url: URL) -> String? {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return describe(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        return status == errSecSuccess ? nil : describe(status)
    }

    private static func describe(_ status: OSStatus) -> String {
        "Code signature check failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
    }
}
