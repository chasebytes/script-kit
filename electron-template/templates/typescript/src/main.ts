import path from 'node:path'
import { app, BrowserWindow } from 'electron'

function createWindow (): void {
  const window = new BrowserWindow({
    width: {{WINDOW_WIDTH}},
    height: {{WINDOW_HEIGHT}},
    minWidth: 640,
    minHeight: 480,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('will-navigate', (event) => event.preventDefault())
  void window.loadFile(path.join(__dirname, '..', 'index.html'))

  if ({{OPEN_DEVTOOLS}}) window.webContents.openDevTools()
}

void app.whenReady().then(() => {
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
