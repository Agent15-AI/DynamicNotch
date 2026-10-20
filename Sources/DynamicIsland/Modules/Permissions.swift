import AppKit
import Foundation

/// Why a permission the user believes they granted is still refused.
///
/// A TCC grant is recorded against the binary's code signature. An ad-hoc
/// signature *is* a hash of the binary, so every rebuild is a different app to
/// macOS: the row stays in System Settings, switched on, while the app is told
/// it has no access. Measured exactly that - toggle on, `CGPreflightScreenCapture`
/// false, `Signature=adhoc`.
///
/// `make.sh` now signs with a real certificate when one exists, which gives a
/// designated requirement with no cdhash in it and makes grants stick. This
/// exists for the case where it could not: never tell someone a permission is
/// off when their System Settings says it is on. Say which of the two things is
/// actually true.
enum Permissions {
    /// True when this build cannot inherit permissions granted to earlier ones.
    static var signatureIsUnstable: Bool {
        guard let code = try? staticCode() else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }

        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let string = text as String?
        else { return false }
        // An ad-hoc requirement pins the binary's own hash. A certificate-backed
        // one names the certificate instead and survives a rebuild.
        return string.contains("cdhash")
    }

    private static func staticCode() throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw CocoaError(.fileReadUnknown) }
        return code
    }

    /// The honest detail line for a refused permission.
    static func detail(for name: String) -> String {
        signatureIsUnstable
            ? "Granted to an older build - switch \(name) off and on"
            : "Allow it in System Settings"
    }

    /// Opens the pane the user actually needs.
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )!)
    }
}
