; =============================================================================
; Ainotes per-user installer (NSIS 3, Unicode).
;
; Built by scripts/build-windows.sh:
;   makensis -DAPPDIR=... -DOUTFILE=... -DVERSION=1.15.0 -DICON=...
;
; Installs under %LOCALAPPDATA%\Programs\Ainotes, so no administrator rights
; are required.  /S performs a silent install; /S in the uninstaller removes
; the application again.
; =============================================================================

Unicode true
ManifestDPIAware true
RequestExecutionLevel user

!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "1.15.0"
!endif
!ifndef APPDIR
  !error "APPDIR must be defined"
!endif
!ifndef OUTFILE
  !error "OUTFILE must be defined"
!endif
!ifndef ICON
  !error "ICON must be defined"
!endif

Name "Ainotes"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\Ainotes"
InstallDirRegKey HKCU "Software\Ainotes" "InstallDir"
BrandingText "Ainotes"

SetCompressor /SOLID lzma
SetCompressorDictSize 64
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Ainotes"
VIAddVersionKey "CompanyName" "envsecure"
VIAddVersionKey "FileDescription" "Ainotes installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 envsecure"

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Ainotes.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Ainotes"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install Ainotes" SecInstall
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${APPDIR}/*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\Ainotes"
  CreateShortCut "$SMPROGRAMS\Ainotes\Ainotes.lnk" "$INSTDIR\Ainotes.exe"
  CreateShortCut "$SMPROGRAMS\Ainotes\Uninstall Ainotes.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortCut "$DESKTOP\Ainotes.lnk" "$INSTDIR\Ainotes.exe"

  ; Per-user application registration.
  WriteRegStr HKCU "Software\Ainotes" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "DisplayName" "Ainotes"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "Publisher" "envsecure"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "DisplayIcon" "$INSTDIR\Ainotes.exe,0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes" "NoRepair" 1

  ; ainotes:// links (the payload uses this scheme internally).
  WriteRegStr HKCU "Software\Classes\ainotes" "" "URL:Ainotes Protocol"
  WriteRegStr HKCU "Software\Classes\ainotes" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\ainotes\DefaultIcon" "" "$INSTDIR\Ainotes.exe,0"
  WriteRegStr HKCU "Software\Classes\ainotes\shell\open\command" "" '"$INSTDIR\Ainotes.exe" "%1"'

  ; Offer Ainotes in "Open with" for the formats it handles, without changing
  ; the user's existing default applications.
  WriteRegStr HKCU "Software\Classes\.md\OpenWithProgids" "Ainotes.md" ""
  WriteRegStr HKCU "Software\Classes\.markdown\OpenWithProgids" "Ainotes.md" ""
  WriteRegStr HKCU "Software\Classes\Ainotes.md" "" "Markdown document"
  WriteRegStr HKCU "Software\Classes\Ainotes.md\DefaultIcon" "" "$INSTDIR\Ainotes.exe,0"
  WriteRegStr HKCU "Software\Classes\.canvas\OpenWithProgids" "Ainotes.canvas" ""
  WriteRegStr HKCU "Software\Classes\Ainotes.canvas" "" "Ainotes canvas"
  WriteRegStr HKCU "Software\Classes\Ainotes.canvas\DefaultIcon" "" "$INSTDIR\Ainotes.exe,0"
  WriteRegStr HKCU "Software\Classes\.base\OpenWithProgids" "Ainotes.base" ""
  WriteRegStr HKCU "Software\Classes\Ainotes.base" "" "Ainotes base"
  WriteRegStr HKCU "Software\Classes\Ainotes.base\DefaultIcon" "" "$INSTDIR\Ainotes.exe,0"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  SetOutPath "$TEMP"

  Delete "$SMPROGRAMS\Ainotes\Ainotes.lnk"
  Delete "$SMPROGRAMS\Ainotes\Uninstall Ainotes.lnk"
  RMDir "$SMPROGRAMS\Ainotes"
  Delete "$DESKTOP\Ainotes.lnk"

  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ainotes"
  DeleteRegKey HKCU "Software\Classes\ainotes"
  DeleteRegKey HKCU "Software\Classes\Ainotes.md"
  DeleteRegKey HKCU "Software\Classes\Ainotes.canvas"
  DeleteRegKey HKCU "Software\Classes\Ainotes.base"
  DeleteRegValue HKCU "Software\Classes\.md\OpenWithProgids" "Ainotes.md"
  DeleteRegValue HKCU "Software\Classes\.markdown\OpenWithProgids" "Ainotes.md"
  DeleteRegValue HKCU "Software\Classes\.canvas\OpenWithProgids" "Ainotes.canvas"
  DeleteRegValue HKCU "Software\Classes\.base\OpenWithProgids" "Ainotes.base"
  DeleteRegKey HKCU "Software\Ainotes"

  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"
SectionEnd
