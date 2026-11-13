import AppKit

// Точка входа. Приложение живёт в строке меню (без иконки в Dock).
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
