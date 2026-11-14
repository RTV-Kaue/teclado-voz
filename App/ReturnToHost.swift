import Foundation

/// Abre de volta o app onde a pessoa estava (WhatsApp etc.).
/// Usa uma função interna do iOS; funciona porque o app é só para uso próprio (fora da App Store).
enum ReturnToHost {
    @discardableResult
    static func open(bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: defSel),
              let ws = cls.perform(defSel)?.takeUnretainedValue() as? NSObject else { return false }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: openSel) else { return false }
        _ = ws.perform(openSel, with: bundleID)
        return true
    }
}
