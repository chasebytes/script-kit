const { contextBridge } = require('electron')

contextBridge.exposeInMainWorld('electronInfo', {
  versions: Object.freeze({
    chrome: process.versions.chrome,
    electron: process.versions.electron,
    node: process.versions.node
  })
})
