//  Baseado em KeyboardHostBundleID (https://github.com/editorss/KeyboardHostBundleID)
//  MIT License - Copyright (c) 2026 editorss
//
//  Descobre em qual app o teclado está aberto (ex.: net.whatsapp.WhatsApp),
//  para o nosso app poder devolver a pessoa para lá depois de ligar o microfone.

import UIKit
import Foundation

enum KeyboardHost {
    static func resolve(from inputVC: UIInputViewController, wait: TimeInterval = 0.05) -> String? {
        guard Thread.isMainThread, inputVC.viewIfLoaded?.window != nil else { return nil }
        if #available(iOS 26.4, *) {
            let generation = KBHostArbiterHook.captureGeneration()
            KBHostArbiterHook.activeArbiterCheck()
            if wait > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: wait)) }
            guard inputVC.viewIfLoaded?.window != nil else { return nil }
            return KBHostArbiterHook.hostBundleId(capturedAfter: generation)
                ?? KBHostArbiterHook.lastCapturedHostBundleId()
        }
        return legacy(from: inputVC)
    }

    /// iOS 16 a 26.3
    private static func legacy(from inputVC: UIInputViewController) -> String? {
        guard let pid = inputVC.parent?.value(forKey: "_hostPID") else { return nil }
        let selector = NSSelectorFromString("defaultService")
        guard let anyClass: AnyObject = NSClassFromString("PKService"),
              let pkService = anyClass as? NSObjectProtocol,
              pkService.responds(to: selector),
              let server = pkService.perform(selector)?.takeUnretainedValue() as? NSObjectProtocol,
              server.responds(to: NSSelectorFromString("personalities"))
        else { return nil }
        let lities = server.perform(NSSelectorFromString("personalities"))?.takeUnretainedValue()
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        guard let infos = lities?.object(forKey: bundleId) as AnyObject?,
              let info = infos.object(forKey: pid) as AnyObject?,
              info.responds(to: NSSelectorFromString("connection")),
              let con = info.perform(NSSelectorFromString("connection"))?.takeUnretainedValue() as? NSObjectProtocol,
              con.responds(to: NSSelectorFromString("_xpcConnection"))
        else { return nil }
        let xpcCon = con.perform(NSSelectorFromString("_xpcConnection"))?.takeUnretainedValue()
        guard let handle = dlopen("/usr/lib/libc.dylib", RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "xpc_connection_copy_bundle_id") else { return nil }
        typealias XPCCopyBundleID = @convention(c) (AnyObject) -> UnsafePointer<CChar>?
        let fn = unsafeBitCast(sym, to: XPCCopyBundleID.self)
        guard let connection = xpcCon, let cstr = fn(connection) else { return nil }
        let result = String(cString: cstr)
        return result.isEmpty ? nil : result
    }
}
