import AppKit
import NapCore
import SwiftUI

@MainActor
final class NapModel: ObservableObject {
    @Published var isOn = false
    @Published var message: String?
    private var nap: NapController?
    private var timer: Timer?

    init() {
        let gamma = DisplayGamma()
        let controller = NapController(displays: gamma, savedURL: NapFiles.savedURL())
        if controller.isOn {
            try? controller.reapply()
        }
        isOn = controller.isOn
        nap = controller
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let nap = self.nap, nap.isOn else { return }
                try? nap.reapply()
            }
        }
    }

    func toggle() {
        guard var controller = nap else { return }
        do {
            if controller.isOn {
                try controller.stop()
            } else {
                try controller.start()
            }
            nap = controller
            isOn = controller.isOn
            message = nil
        } catch NapDisplayError.noDisplay {
            nap = controller
            message = "没有找到外接显示器"
        } catch {
            nap = controller
            message = "切换失败"
        }
    }

    func quit() {
        if var controller = nap, controller.isOn {
            do {
                try controller.stop()
                nap = controller
            } catch {
                nap = controller
                message = "恢复亮度失败，午休还开着"
                return
            }
        }
        NSApplication.shared.terminate(nil)
    }
}

@main
struct NapModeApp: App {
    @StateObject private var model = NapModel()

    var body: some Scene {
        MenuBarExtra {
            Button(model.isOn ? "结束午休" : "开始午休") {
                model.toggle()
            }
            if let message = model.message {
                Text(message)
            }
            Divider()
            Button("退出") {
                model.quit()
            }
        } label: {
            Text(model.isOn ? "午休中" : "午休")
        }
    }
}
