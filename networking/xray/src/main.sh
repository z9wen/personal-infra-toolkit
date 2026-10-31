# ===== Entry Point =====
# Runs after every module is loaded, so initialization can use any function.
initVar "$1"
checkSystem
checkCPUVendor
detectPanelNginxPath
readInstallType
readInstallProtocolType
readConfigHostPathUUID
readCustomPort
checkNginxEnvironment
trap restoreStoppedNginx EXIT
cronFunction
menu
