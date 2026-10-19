import SwiftUI
import AppKit

struct LumaTraceApp: App {
    @AppStorage("timeimprint.language") private var language = AppLanguage.systemDefault.rawValue
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup {
            ContentView(store: store).frame(minWidth: 900, minHeight: 600)
                .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.systemDefault.locale)
        }.defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) { Button(tr("添加监测文件夹…")) { store.addRoot() }.keyboardShortcut("o"); Button(tr("立即扫描")) { store.scan() }.keyboardShortcut("r") }
        }
        Settings { PreferencesView(store: store).frame(width: 680).environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.systemDefault.locale) }
    }
}

@main enum LumaTraceMain {
    @MainActor static func main() async {
        ProcessInfo.processInfo.processName = AppBrand.name
        if CommandLine.arguments.contains("--generate-memories") { await MemoryBackground.run() }
        else { LumaTraceApp.main() }
    }
}
