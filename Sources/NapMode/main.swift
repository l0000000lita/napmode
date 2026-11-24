import AppKit
import Darwin
import NapCore
import SwiftUI

@MainActor
final class NapModel: ObservableObject {
    @Published var phase: NapPhase = .off
    @Published var message: String?
    private var nap: NapController?
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var finishing = false

    init() {
        let gamma = DisplayGamma()
        var controller = NapController(displays: gamma, savedURL: NapFiles.savedURL())
        if controller.phase == .napping {
            controller.reapply()
        } else if controller.phase == .pendingRestore {
            controller.stop()
        }
        nap = controller
        publish(controller)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.quit()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var menuTitle: String {
        switch phase {
        case .napping:
            return "结束午休"
        case .pendingRestore:
            return "重试恢复"
        case .off:
            return "开始午休"
        }
    }

    var statusTitle: String {
        switch phase {
        case .napping:
            return "午休中"
        case .pendingRestore:
            return "待恢复"
        case .off:
            return "午休"
        }
    }

    func primary() {
        guard var controller = nap else { return }
        switch controller.phase {
        case .off:
            do {
                try controller.start()
                message = controller.notice
            } catch NapDisplayError.noDisplay {
                message = "没有找到外接显示器"
            } catch {
                message = controller.notice ?? "切换失败"
            }
        case .napping, .pendingRestore:
            controller.stop()
            message = controller.notice
        }
        nap = controller
        publish(controller)
    }

    func quit() {
        finish()
        NSApplication.shared.terminate(nil)
    }

    private func syncTimer() {
        if phase == .napping {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reapplyIfNapping()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reapplyIfNapping() {
        guard let controller = nap, controller.phase == .napping else { return }
        controller.reapply()
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        timer?.invalidate()
        timer = nil
        guard var controller = nap else { return }
        controller.stop()
        nap = controller
        phase = controller.phase
        message = controller.notice
    }

    private func publish(_ controller: NapController) {
        phase = controller.phase
        if message == nil {
            message = controller.notice
        }
        syncTimer()
    }
}

@main
struct NapModeApp: App {
    @StateObject private var model = NapModel()

    var body: some Scene {
        MenuBarExtra {
            Button(model.menuTitle) {
                model.primary()
            }
            if let message = model.message {
                Text(message)
            }
            Divider()
            Button("退出") {
                model.quit()
            }
        } label: {
            Text(model.statusTitle)
        }
    }
}
