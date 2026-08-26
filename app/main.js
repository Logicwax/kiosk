// Minimal Electron main process for the kiosk image.
//
// A single frameless, full-screen BrowserWindow that the binary opens
// directly (no window manager needed — Chromium creates and fullscreens its
// own top-level window). The renderer just loads the webpack-built renderer entry.
const { app, BrowserWindow, screen } = require('electron')

// We run with NO window manager (launched straight from .xinitrc).
// `fullscreen: true` / `kiosk: true` are WM hints, so with no WM they do
// nothing and the window stays at its default ~800x600. Instead — we size the window
// explicitly to the primary display's dimensions, which X honours without a WM.
//  `screen` must be queried after the app is ready.
function createWindow() {
  const display = screen.getPrimaryDisplay()
  const { width, height } = display.size

  const win = new BrowserWindow({
    x: display.bounds.x,
    y: display.bounds.y,
    width,
    height,
    frame: false,
    autoHideMenuBar: true,
    backgroundColor: '#0b0f17',
    webPreferences: {
      // Static page only — no Node access or devtools in the renderer.
      contextIsolation: true,
      nodeIntegration: false,
      devTools: false,
    },
  })

  win.removeMenu()
  // MAIN_WINDOW_WEBPACK_ENTRY is injected by @electron-forge/plugin-webpack
  // and points at the webpack-built renderer entry.
  win.loadURL(MAIN_WINDOW_WEBPACK_ENTRY)
  win.once('ready-to-show', () => win.show())
}

app.whenReady().then(() => {
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => app.quit())
