type ElectronInfo = {
  versions: Readonly<Record<'chrome' | 'electron' | 'node', string>>
}

declare global {
  interface Window {
    electronInfo: ElectronInfo
  }
}

for (const [name, version] of Object.entries(window.electronInfo.versions)) {
  const target = document.querySelector(`[data-version="${name}"]`)
  if (target) target.textContent = version
}

export {}
