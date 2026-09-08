const versions = window.electronInfo.versions

for (const [name, version] of Object.entries(versions)) {
  const target = document.querySelector(`[data-version="${name}"]`)
  if (target) target.textContent = version
}
