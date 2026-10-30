@echo off
setlocal EnableExtensions
title OpenCode
REM ============================================================
REM  OpenCode launcher  (v2.2 auto-resume build)
REM  WARP egress rotation + dependency bootstrap + auto-resume.
REM
REM  Usage:
REM    double-click                     -> folder menu
REM    drag a folder onto this file     -> opens in that folder
REM    OpenCode.bat "D:\work\project"   -> opens in that folder
REM
REM  This script never moves, renames or deletes your chats, your
REM  history or any file of yours, except option [5] Deep reset,
REM  which asks first and archives before it deletes.
REM
REM  Everything is user-mode. UAC is only needed if WARP
REM  has to be installed, and WARP is optional: without it the
REM  launcher still starts opencode, only rotation is skipped.
REM
REM  Works on Windows 10/11, x64 / arm64 / 32-bit (limited), any
REM  system language. The UI text is English only.
REM
REM  v2.1 fixes:
REM   1. menu never parses a WARP path inside a ( block )
REM   2. direct IP fetch ignores stale HTTP_PROXY/HTTPS_PROXY
REM   3. rotation only accepts an IP whose trace says warp=on
REM   4. every warp-cli call logs failures to wcli.log
REM   5. taskkill closes opencode (service stop restored in v2.2)
REM   6. deep archive works across volumes, copy-verify-delete
REM   7. dead HAS_WARP variable removed
REM   8. placebo spoof variables removed
REM   9. quota match broadened, log path fallback, missing-log warning
REM  10. downloads: curl -f + size gate (no public checksums exist)
REM  11. second launcher instance locked out; unique temp files
REM  12. all PowerShell calls use %PSX% and force TLS 1.2
REM  13. every path reaches PowerShell through the environment
REM  14. settings validated numeric; timeout multiplied in PowerShell
REM
REM  v2.2 auto-resume:
REM   A. a watcher tails the opencode log while the TUI runs. any
REM      fatal error (drain failure, usage limit, rate limit, quota,
REM      credits) kills the TUI and starts a rotation. recoverable
REM      errors are ignored: the watcher only fires when the chat is
REM      actually stuck.
REM   B. every candidate IP is probed with one cheap message on a
REM      throwaway session before it is handed to you. burned IPs
REM      are skipped automatically. IP_FIND_MAX=0 keeps hunting.
REM   C. after a working IP is found the launcher sends RESUME_MSG
REM      with --continue, so the chat picks up at the exact message
REM      where it stopped, then reopens the TUI on the same session.
REM      the probe session is deleted first so -c points at YOUR chat.
REM ============================================================

REM ---------- settings (edit freely) --------------------------------
REM Rotation attempts for infrastructure problems (tunnel not up).
set "ROTATE_TRIES_MAX=4"
REM How many IPs the probe may reject as burned before giving up.
REM 0 = keep hunting until one works (Ctrl+C stops the launcher).
set "IP_FIND_MAX=0"
REM Seconds to wait after (re)connecting WARP.
set "WARP_WAIT=6"
REM Seconds a single warp-cli call may take before it is killed.
set "WARP_CALL_TIMEOUT=15"
REM 1 = watch the log while opencode runs, rotate on any fatal error.
set "WATCH=1"
REM Message sent automatically so the chat continues where it stopped.
set "RESUME_MSG=continue"
REM 1 = the automatic resume runs unattended (auto-approves tool
REM permissions). 0 = the resume may stop and wait for permission.
set "RESUME_AUTO=1"
REM Model used by the IP probe: one cheap message per candidate IP.
set "PROBE_MODEL=opencode/deepseek-v4.1-flash-free"
REM PROBE=0 skips the probe entirely (IPs are accepted without testing).
set "PROBE=0"

REM ---------- internal ---------------------------------------------
REM Local port where the WARP proxy listens (WARP proxy mode).
set "PROXY_PORT=40000"
REM HTTP and SOCKS5 forms of the same local proxy, used by curl.
set "PROXY=http://127.0.0.1:%PROXY_PORT%"
set "SOCKS_PROXY=socks5h://127.0.0.1:%PROXY_PORT%"
REM Endpoint that returns ip= and warp= lines, used to check the IP.
set "TRACE_URL=https://www.cloudflare.com/cdn-cgi/trace"
REM Official download address for the WARP installer (64-bit MSI).
set "WARP_MSI_URL=https://downloads.cloudflareclient.com/v1/download/windows/ga"
REM Hosts that must never go through the proxy.
set "NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,[::1]"
REM Default PowerShell command; replaced below by the full path if it exists.
set "PSX=powershell"
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSX=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM UTF-8 console: folder paths in any system language survive the
REM write/read round trip in lastfolder.txt
REM Note: chcp 65001 changes the code page of the whole console window
REM for as long as this launcher runs, not only for this script.
chcp 65001 >nul 2>&1

REM Where opencode keeps its data (chats, database, auth).
set "DATA_DIR=%USERPROFILE%\.local\share\opencode"
REM Log file the watcher and the quota check read. Falls back to the
REM LOCALAPPDATA location if the first one does not exist.
set "LOGFILE=%DATA_DIR%\log\opencode.log"
if not exist "%LOGFILE%" if exist "%LOCALAPPDATA%\opencode\log\opencode.log" set "LOGFILE=%LOCALAPPDATA%\opencode\log\opencode.log"
REM Folder for the launcher own state files (last folder, last IP, logs, locks).
set "STATE_DIR=%LOCALAPPDATA%\opencode-launcher"
set "LASTFOLDER=%STATE_DIR%\lastfolder.txt"
REM Run-time flags that are set and cleared during the session.
REM RESUME: 1 when the next launch should continue the last chat.
set "RESUME="
REM COLD: 1 = fresh start, 0 = continue the same session.
set "COLD=0"
REM WARP_UP: 1 once WARP has been connected in this session.
set "WARP_UP=0"
REM QHIT / FHIT: set to 1 when a quota or fatal error is found in the log.
set "QHIT="
set "FHIT="
REM IP and WARP hold the current exit IP and the WARP path, if found.
set "IP="
set "WARP="
REM OC_CMD: full path of the opencode command, filled by find_opencode.
set "OC_CMD="
REM one fixed throwaway session for every probe: deleted after a pass
REM so that --continue always points at the real chat, never the probe
set "OC_PROBE_ID=ses_probe0000000"
REM fatal error family: anything that ends the chat without the user
REM choosing to stop. The pattern is matched against log lines.
set "OC_PAT=level=ERROR.*(Failed to drain Session|free usage limit|usage limit reached|rate limit|out of usage|insufficient credits|payment required)"

REM 32-bit Windows: PROCESSOR_ARCHITEW6432 is defined when a 32-bit
REM process runs on a 64-bit OS, so x86 alone is not proof.
REM REAL86=1 means a true 32-bit Windows system (WARP and opencode
REM standalone builds are not available there).
set "REAL86=0"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if not defined PROCESSOR_ARCHITEW6432 set "REAL86=1"

REM Validate the numeric settings: invalid values fall back to defaults.
call :numcfg ROTATE_TRIES_MAX 4
call :numcfg WARP_WAIT 6
call :numcfg WARP_CALL_TIMEOUT 15
REM this one may legitimately be 0 (hunt with no limit)
call :numcfg0 IP_FIND_MAX 0

REM Create the state folder if it is missing, then check the single-instance lock.
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
call :lock_check

REM ============================================================
REM  1) WORKING FOLDER
REM ============================================================
REM No parenthesised block may expand a path variable: a folder like
REM "Program Files (x86)" unbalances the block while it is parsed.
REM Everything here is sequential ifs and gotos instead.
REM If a folder was passed as argument (drag and drop), use it directly.
if "%~1"=="" goto :folder
if not exist "%~1\" goto :folder
set "OPFOLDER=%~1"
goto :folder_ok

REM Folder menu: reopen last folder, use the current one, browse, or exit.
:folder
cls
echo ============================================================
echo   OpenCode - choose a folder to work in
echo ============================================================
echo.
set "OPFOLDER="
set "LASTPATH="
REM Read the saved folder path, strip quotes, and drop it if it no longer exists.
if exist "%LASTFOLDER%" set /p LASTPATH=<"%LASTFOLDER%"
if defined LASTPATH set "LASTPATH=%LASTPATH:"=%"
if defined LASTPATH if not exist "%LASTPATH%\" set "LASTPATH="
echo.
echo   [1] Reopen the last folder
REM Show the saved path only when there is one; otherwise show a placeholder.
if defined LASTPATH goto :folder_lp
echo       ^(nothing saved yet^)
goto :folder_m2
:folder_lp
echo       "%LASTPATH%"
:folder_m2
echo   [2] Use this folder
echo       "%CD%"
echo   [3] Browse for a folder...
echo   [4] Exit
echo.
echo   One key, no Enter.
echo.
REM choice returns the key number through errorlevel: check highest first.
choice /c 1234 /n /m "Pick: "
if errorlevel 4 goto :quit
if errorlevel 3 goto :pick_folder
if errorlevel 2 goto :use_current
REM Option 1 with nothing saved: explain, wait, and show the menu again.
if not defined LASTPATH (
  echo.
  echo   No folder saved yet. Use [2] or [3] this time.
  timeout /t 3 /nobreak >nul 2>&1
  goto :folder
)
set "OPFOLDER=%LASTPATH%"
goto :folder_ok

REM Option 2: the folder the launcher was started from.
:use_current
set "OPFOLDER=%CD%"
goto :folder_ok

REM Option 3: open a Windows folder-picker dialog through PowerShell.
:pick_folder
echo.
echo   Choose a folder in the dialog...
REM the result travels through a file, never through the command line:
REM a quoted powershell path at the head of a for /f command gets its
REM quotes stripped by cmd /c and the whole call dies.
set "OPFOLDER="
REM Temporary file that receives the chosen folder path (random name).
set "OC_OUT=%TEMP%\oc_pick_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_PICK=%OC_OUT%"
REM Show the dialog and write the selected path to OC_PICK. Errors are ignored.
"%PSX%" -NoProfile -STA -Command "try{Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = 'Folder to open OpenCode in'; $d.ShowNewFolderButton = $true; if ($d.ShowDialog() -eq 'OK') { [IO.File]::WriteAllLines($env:OC_PICK, $d.SelectedPath) } }catch{}" >nul 2>&1
REM Read the chosen path back, then remove the temporary file.
if exist "%OC_OUT%" for /f "usebackq delims=" %%i in ("%OC_OUT%") do set "OPFOLDER=%%i"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
REM Nothing chosen (dialog cancelled): ask whether to try again.
if not defined OPFOLDER (
  echo.
  echo   No folder selected.
  choice /c YN /n /m "   Try again? [Y/N]: "
  if not errorlevel 2 goto :pick_folder
  goto :folder
)
goto :folder_ok

REM Check that the chosen folder exists before entering it.
:folder_ok
if exist "%OPFOLDER%\" goto :folder_ok2
echo.
echo   Folder not found: "%OPFOLDER%"
timeout /t 3 /nobreak >nul 2>&1
goto :folder

REM Enter the folder. pushd is used because it also accepts UNC (network) paths.
:folder_ok2
pushd "%OPFOLDER%" 2>nul
if not errorlevel 1 goto :folder_ok3
echo.
echo   Cannot enter: "%OPFOLDER%"
timeout /t 3 /nobreak >nul 2>&1
goto :folder

REM POPPED marks that a pushd was done, so :quit runs popd.
REM The path is saved in quotes; the quotes are removed when it is read back.
:folder_ok3
set "POPPED=1"
REM quoted write + quote-strip on read: survives & and () in the path
>"%LASTFOLDER%" echo "%CD%"
title OpenCode
echo.
echo   Working in: "%CD%"
echo.

REM ============================================================
REM  2) DEPENDENCIES
REM ============================================================
REM HAVE_CURL=1 when curl.exe is available (it is used for downloads and IP checks).
set "HAVE_CURL=1"
where curl.exe >nul 2>&1
if errorlevel 1 set "HAVE_CURL=0"

REM ---------- WARP (optional) ----------
REM Look for warp-cli. If found, skip the WARP setup and go to opencode.
call :find_warp
if defined WARP goto :check_opencode

REM 32-bit systems cannot run the WARP installer: skip the offer.
if "%REAL86%"=="1" goto :no_warp_32

echo   [!] Cloudflare WARP not found - IP rotation will be disabled.
echo       Install it later from 1.1.1.1 if you want the rotation.
echo.
REM Offer the install. Answering N continues without rotation.
choice /c YN /n /m "   Try to download and install WARP now? [Y/N]: "
if errorlevel 2 goto :check_opencode
call :install_warp
call :find_warp
if defined WARP goto :warp_ready
echo   [!] WARP still not available - continuing without rotation.
echo       warp-cli errors, if any, are in %STATE_DIR%\wcli.log
goto :check_opencode

REM Message shown on 32-bit systems, then continue without WARP.
:no_warp_32
echo   [!] Cloudflare WARP publishes 64-bit Windows builds only.
echo       On this 32-bit system rotation is disabled.
goto :check_opencode

REM WARP was installed or found: confirm and continue.
:warp_ready
echo   [ok] WARP ready.

REM ---------- opencode ----------
REM Look for the opencode command. If found, go to the menu.
:check_opencode
call :find_opencode
if defined OC_CMD goto :ready

REM Not found: install it (npm first, then the standalone build).
echo   [auto-install] opencode not found, fetching it...
call :install_opencode
call :find_opencode
if defined OC_CMD (
  echo   [ok] opencode ready.
  goto :ready
)
REM The install failed: show a manual link and stop.
echo   ERROR: opencode install failed or is not on PATH.
echo   Get it by hand: https://github.com/sst/opencode/releases
pause
goto :quit

REM Both dependencies are ready. Short pause before the menu.
:ready
timeout /t 1 /nobreak >nul 2>&1

REM ============================================================
REM  3) MENU
REM ============================================================
REM Main menu. Each pass redraws the screen and checks the IP.
:menu_loop
REM keep the lock fresh so a second launcher can tell it is alive
REM The lock folder gets a new stamp each time, so its age shows it is alive.
if exist "%STATE_DIR%\lock\" echo(%RANDOM%>"%STATE_DIR%\lock\stamp" 2>nul
cls
echo ============================================================
echo   OpenCode
echo.
echo   Folder : "%CD%"
REM Show the WARP path if WARP was found; otherwise say rotation is off.
if defined WARP goto :menu_warp_path
echo   WARP   : none ^(rotation disabled^)
goto :menu_warp_done
:menu_warp_path
echo   WARP   : "%WARP%"
:menu_warp_done
echo ============================================================
echo.

REM Connect WARP the first time the menu is shown in this session.
REM Later passes skip this step, because WARP_UP is already 1.
if not defined WARP goto :menu_ip
if "%WARP_UP%"=="1" goto :menu_ip
call :warp_up
set "WARP_UP=1"
REM Read the current exit IP through the proxy. WFLAG receives warp=on or off.
:menu_ip
set "WFLAG="
if defined WARP call :getip2 IP WFLAG
if defined IP goto :menu_ip_ok
REM No IP could be read: show "unknown" with the reason.
set "IP=unknown"
if defined WARP set "IP=unknown - WARP proxy not answering"
:menu_ip_ok
echo   Exit IP: %IP%
echo.
echo   What do you want to do?
echo.
echo   [1] Fresh start   - get a new IP, then open OpenCode
echo                       (your chats and history stay untouched)
echo   [2] Continue      - same IP, open OpenCode as it was
echo   [3] Change IP     - rotate only, do not open OpenCode
echo   [4] Folder        - work in a different folder
echo   [5] Deep reset    - kill opencode, move chats to the Desktop,
echo                       clear saved tokens, open a fresh session
echo   [6] Exit
echo.
echo   One key, no Enter.
echo.
REM Read the menu choice. Highest number is checked first.
choice /c 123456 /n /m "Pick: "
if errorlevel 6 goto :quit
if errorlevel 5 goto :run_deep
if errorlevel 4 goto :folder
if errorlevel 3 goto :rotate
if errorlevel 2 goto :run_warm
goto :run_cold

REM Option 1 (fresh start): COLD=1 asks for a new IP before launching.
:run_cold
set "COLD=1"
goto :run

REM Option 2 (continue): COLD=0 keeps the current IP and session.
:run_warm
set "COLD=0"
goto :run

REM -- the discord-style reset: close, archive, wipe tokens, reopen --
REM Option 5. Destructive part: asks first, then closes opencode,
REM moves the chats to the Desktop and clears tokens.
:run_deep
echo.
echo --- deep reset -----------------------------------------------
echo   This closes opencode, moves your chats to the Desktop,
echo   clears the saved tokens and opens a brand new session.
echo   It is the only action in this script that touches your files.
echo.
choice /c yn /n /m "  Do that now? [Y/N] "
if errorlevel 2 goto :menu_loop
call :stop_opencode
call :deep_archive
call :clear_tokens
REM After a reset there is nothing to resume: start cold.
set "RESUME="
set "COLD=1"
goto :run

REM Launch step. Checks the proxy first, then starts opencode.
:run
echo.
if "%COLD%"=="1" echo --- fresh start ---------------------------------------------
if not "%COLD%"=="1" echo --- continue ------------------------------------------------
echo     "%CD%"

REM never launch through a dead proxy, and never "rotate" into a
REM direct connection: the gate asks instead of leaking silently.
REM Without WARP there is no proxy to check: go straight to launch.
if not defined WARP goto :run_noproxy
REM Hand the proxy to this process only. If it does not answer, ask the user.
call :export_proxy
if not errorlevel 1 goto :run_gate_ok
echo   [!] WARP proxy is not answering - rotation has no effect.
echo       Going direct would run opencode on your real IP.
choice /c YN /n /m "   Continue without WARP? [Y/N]: "
if errorlevel 2 goto :menu_loop
goto :run_noproxy
REM Proxy is working: continue with the gate checks.
:run_gate_ok
REM the free tier counts per egress IP: never launch a fresh start on
REM the same IP the previous run used.
if "%COLD%"=="1" call :ensure_new_ip
REM the background service is the process that talks to the API: it
REM must be born with the proxy env. if it was ever started direct
REM (for example by hand before WARP existed), restart it once.
REM The svc_proxied marker records that the restart already happened.
if not exist "%STATE_DIR%\svc_proxied" call "%OC_CMD%" service restart >nul 2>&1
if exist "%STATE_DIR%\svc_proxied" goto :run_marked
echo ok>"%STATE_DIR%\svc_proxied"
:run_marked
REM Common path for launching with or without WARP.
:run_noproxy

REM Remember the log size before launch, so the watcher and the quota
REM check only read what this run writes.
set "SIZE_BEFORE=0"
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "SIZE_BEFORE=%%~zS"
REM WHY records the reason the run ended (exit, quota, stop, watcher).
set "WHY="

REM FLAGS gets --continue when resuming the last chat.
set "FLAGS="
if defined RESUME set "FLAGS=--continue"
if defined RESUME echo   reopening the last session on the same chat...
set "RESUME="

REM Start the watcher, open the TUI, and stop the watcher when it closes.
call :watch_start
call :launch
call :watch_stop
REM Save the exit code of the TUI before anything else overwrites it.
set "EC=%errorlevel%"
REM the proxy belongs to the child process only: clear it so later
REM direct fetches never inherit a proxy that may already be dead.
set "HTTP_PROXY="
set "HTTPS_PROXY="
echo.

REM the watcher firing outranks the exit code: a killed TUI exits
REM nonzero, but the marker tells us WHY and where to go.
REM If the watcher left a hit marker, it killed the TUI because of a fatal error.
if not exist "%STATE_DIR%\watch_hit.txt" goto :run_no_hit
del /f /q "%STATE_DIR%\watch_hit.txt" >nul 2>&1
echo   [watch] a fatal error cut the chat - rotating and resuming it.
set "WHY=watcher"
goto :quota_rotate
REM No watcher hit. A nonzero exit code means opencode crashed.
:run_no_hit
if not "%EC%"=="0" goto :exit_rotate
REM Without WARP there is nothing to rotate: go back to the menu.
if not defined WARP goto :closed
REM A clean exit: check the log for a quota message before deciding.
call :check_quota
if defined QHIT set "WHY=quota"
if defined QHIT goto :quota_rotate

REM Normal close: offer a new IP and resume, or go to the menu.
:closed
echo OpenCode closed.
if not defined WARP goto :menu_loop
echo.
echo   Ctrl+C is the stop button: one press hands you a new IP,
echo   resumes the chat where it stopped and reopens the session.
REM Default is Y after 5 seconds: the auto-resume happens unless N is pressed.
choice /c yn /n /t 5 /d y /m "  New IP and resume in 5s [Y], N for the menu: "
if errorlevel 2 goto :menu_loop
set "WHY=stop"
goto :quota_rotate



REM opencode exited with a nonzero code and the watcher did not catch it.
:exit_rotate
set "WHY=exit"

REM Common exit path for rotation. WHY is one of: exit, quota, stop, watcher.
REM Only the message for the current WHY value is shown.
:quota_rotate
if "%WHY%"=="exit" echo OpenCode exited with code %EC%.
if "%WHY%"=="quota" echo Free quota reached on this IP.
if "%WHY%"=="stop" echo Reopening on a new IP.
if "%WHY%"=="watcher" echo Fatal error caught by the watcher - finding a working IP.
REM Without WARP there is no rotation possible.
if not defined WARP goto :menu_loop
echo Getting a new IP before the next attempt...
timeout /t 3 /nobreak >nul 2>&1

REM ============================================================
REM  3b) ROTATION + PROBE + RESUME
REM ============================================================
REM Automatic rotation: keep trying until a verified, unused IP answers the probe.
REM ROTATE_TRIES counts attempts; PROBE_TRIES counts IPs the probe rejected.
:auto_rotate
set /a ROTATE_TRIES=0
set /a PROBE_TRIES=0
:rotate_loop
set /a ROTATE_TRIES+=1
if %ROTATE_TRIES% GTR %ROTATE_TRIES_MAX% goto :rotate_fail
REM Drop the current WARP connection and its registration.
echo [%ROTATE_TRIES%] disconnect...
call :wcli disconnect
echo [%ROTATE_TRIES%] deleting old registration...
call :wcli registration delete
timeout /t 1 /nobreak >nul 2>&1
REM A new registration gets a new exit IP from Cloudflare.
echo [%ROTATE_TRIES%] new registration...
call :wcli registration new
timeout /t 1 /nobreak >nul 2>&1
echo [%ROTATE_TRIES%] reconnect...
call :warp_up
set "WARP_UP=1"
echo [%ROTATE_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1

REM an IP counts only when the trace came back through the proxy AND
REM says warp=on. anything else is a retry, never a silent launch.
call :getip2 IPN WFLAG
if not defined IPN goto :rotate_retry
if not "%WFLAG%"=="on" goto :rotate_retry
REM An IP equal to the previous one does not count: retry for a new one.
if /i "%IPN%"=="%IP%" goto :rotate_retry
echo [%ROTATE_TRIES%] new exit IP: %IPN% ^(WARP verified^)

REM probe: one cheap message on the throwaway session. burned IP ->
REM skip it and rotate again. this does not consume the infrastructure
REM budget, it consumes the probe budget (IP_FIND_MAX, 0 = no limit).
REM With PROBE=0 the probe is skipped and the IP is accepted directly.
if "%PROBE%"=="0" goto :rotate_good
echo [%ROTATE_TRIES%] probing if this IP can still talk...
call :probe_once
if not errorlevel 1 goto :rotate_good
REM The probe failed: this IP is burned. Undo the attempt count and count the probe.
set /a ROTATE_TRIES-=1
set /a PROBE_TRIES+=1
REM IP_FIND_MAX=0 means no limit on probes. Otherwise stop after the limit.
if "%IP_FIND_MAX%"=="0" goto :probe_endless
if %PROBE_TRIES% GTR %IP_FIND_MAX% goto :probe_exhausted
:probe_endless
echo [%PROBE_TRIES%] IP already burned, rotating - hunting with no cap ^(Ctrl+C stops^)...
goto :rotate_loop
:probe_exhausted
echo.
echo   [!] %PROBE_TRIES% IPs probed, every one of them already burned.
goto :rotate_fail

REM A verified IP that passed the probe: save it, mark the resume, and resume the chat.
:rotate_good
echo [%ROTATE_TRIES%] IP %IPN% works.
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
set "RESUME=1"
set "COLD=0"
goto :resume_and_run

REM Not a usable IP yet (no answer, or WARP not on): try again.
:rotate_retry
echo [%ROTATE_TRIES%] no verified WARP IP yet, retrying...
goto :rotate_loop

REM Rotation gave up: remove the probe session and pause for the user to read the log.
:rotate_fail
REM never leave the probe session behind as the last session
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
echo   [!] giving up this cycle - warp-cli errors in %STATE_DIR%\wcli.log
pause
goto :menu_loop

REM -- send the resume message so the chat continues, then open the
REM    TUI on the same session. a fresh fatal here loops back into
REM    the rotation.
REM Send RESUME_MSG to the existing session. Then reopen the TUI with --continue.
:resume_and_run
if not defined RESUME goto :run
echo   sending "%RESUME_MSG%" so the chat picks up where it stopped...
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
REM RZB stores the log size before the resume message, to scan only its output.
set "RZB=0"
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "RZB=%%~zS"
REM RESUME_AUTO=1 adds --auto, which approves tool permissions without asking.
set "RARGS=-c"
if "%RESUME_AUTO%"=="1" set "RARGS=-c --auto"
call "%OC_CMD%" run %RARGS% "%RESUME_MSG%" >nul 2>&1
set "REC=%errorlevel%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
REM A fatal line or a nonzero exit code means the resume failed: rotate again.
call :scan_log %RZB%
if defined FHIT goto :resume_fatal
if not "%REC%"=="0" goto :resume_fatal
echo   chat resumed on the new IP.
goto :run
REM The resume hit a limit: go back to the rotation with WHY=quota.
:resume_fatal
echo   [!] the resume itself hit a limit - rotating again.
set "WHY=quota"
goto :quota_rotate

REM Option 3: rotate only, without opening opencode. Shows the result and waits.
:rotate
if not defined WARP (
  echo.
  echo WARP is not available - nothing to rotate.
  pause
  goto :menu_loop
)
echo.
echo Requesting a new WARP registration...
call :wcli disconnect
call :wcli registration delete
timeout /t 1 /nobreak >nul 2>&1
call :wcli registration new
timeout /t 1 /nobreak >nul 2>&1
call :warp_up
set "WARP_UP=1"
echo waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 IPN WFLAG
if defined IPN if "%WFLAG%"=="on" goto :rotate_ok
REM Explain why the rotation failed: no answer or tunnel down.
echo   [!] no verified WARP IP.
if defined IPN if not "%WFLAG%"=="on" echo       the trace answered but warp=off - the tunnel is not up.
if not defined IPN echo       no trace answer - the proxy on port %PROXY_PORT% is down.
echo       warp-cli errors land in %STATE_DIR%\wcli.log
pause
goto :menu_loop
REM Rotation succeeded. Report whether the IP changed or stayed the same.
:rotate_ok
if /i not "%IPN%"=="%IP%" goto :rotate_new
echo   same IP as before: %IPN%
goto :rotate_done
:rotate_new
echo   New exit IP: %IPN% ^(WARP verified^)
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
:rotate_done
echo.
pause
goto :menu_loop

REM ============================================================
REM  4) SUBROUTINES
REM ============================================================

REM -- launch opencode with a tracked PID ----------------------------
REM The TUI runs through a small PowerShell host in this same console
REM so the launcher knows the exact PID (written to tui.pid). The
REM watcher kills exactly that process tree, and .cmd shims from npm
REM installs work the same as plain .exe builds.
REM Start opencode, save its PID to tui.pid, wait for it to exit, and return its exit code.
:launch
set "OC_EXE=%OC_CMD%"
set "OC_FLAGS=%FLAGS%"
set "OC_PIDF=%STATE_DIR%\tui.pid"
if exist "%OC_PIDF%" del /f /q "%OC_PIDF%" >nul 2>&1
REM Start-Process -ArgumentList treats one spaced string as ONE argument:
REM split the flags into tokens first (FLAGS is only --continue here).
REM .cmd and .bat files are started through cmd.exe, others are started directly.
"%PSX%" -NoProfile -Command "$exe=$env:OC_EXE; $a=@(); if($env:OC_FLAGS){ $a=([string]$env:OC_FLAGS) -split [char]32 }; $p=$null; if($exe -match '[.](cmd|bat)$'){ $p=Start-Process cmd.exe -ArgumentList (@('/c',$exe)+$a) -NoNewWindow -PassThru } else { $p=Start-Process $exe -ArgumentList $a -NoNewWindow -PassThru }; if(-not $p){ exit 1 }; $null=$p.Handle; Set-Content -LiteralPath $env:OC_PIDF -Value $p.Id; [void]$p.WaitForExit(); if($p.ExitCode -ne $null){ exit $p.ExitCode }; exit 1"
set "EC=%errorlevel%"
goto :eof

REM -- the watcher: tail the log, kill the TUI only when stuck --------
REM Polls every 2 seconds. On a fatal pattern it waits 4 seconds and
REM re-reads: if normal activity (INFO/DEBUG) followed the error, the
REM session recovered on its own and is left alone. Only a stuck chat
REM gets killed, and it kills exactly the tracked PID tree.
REM The watcher runs in the background (start /b). It reads the log
REM from SIZE_BEFORE onward, and if the TUI is still alive after a
REM confirmed fatal error, it writes watch_hit.txt and kills the tree.
REM Starts the background PowerShell watcher. Does nothing if WATCH is not 1 or WARP is absent.
:watch_start
if not "%WATCH%"=="1" goto :eof
if not defined WARP goto :eof
REM Clear leftovers from a previous run.
if exist "%STATE_DIR%\watch_hit.txt" del /f /q "%STATE_DIR%\watch_hit.txt" >nul 2>&1
if exist "%STATE_DIR%\watch.pid" del /f /q "%STATE_DIR%\watch.pid" >nul 2>&1
REM Paths and settings passed to the watcher through the environment.
set "OC_WPIDF=%STATE_DIR%\watch.pid"
set "OC_TPIDF=%STATE_DIR%\tui.pid"
set "OC_HITF=%STATE_DIR%\watch_hit.txt"
set "OC_LOGF=%LOGFILE%"
set "OC_OFF=%SIZE_BEFORE%"
set "OC_FATPAT=%OC_PAT%"
REM Watcher body (PowerShell, one line). Its steps in order:
REM  1) save its own PID, 2) wait up to 60 s for the TUI PID,
REM  3) loop every 2 s: read new log bytes, look for a fatal pattern,
REM     re-read after 4 s, ignore it if INFO or DEBUG lines followed,
REM     otherwise write the hit marker and kill the TUI process tree.
start "" /b "%PSX%" -NoProfile -Command "$PID | Set-Content -LiteralPath $env:OC_WPIDF; $tpid=0; $off=0; if($env:OC_OFF){$off=[int64]$env:OC_OFF}; $dl=(Get-Date).AddSeconds(60); while($tpid -eq 0){ if((Get-Date) -gt $dl){exit 0}; if(Test-Path -LiteralPath $env:OC_TPIDF){ $c=(Get-Content -LiteralPath $env:OC_TPIDF -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){$tpid=[int]$c} }; if($tpid -eq 0){Start-Sleep -Seconds 1} }; while($true){ Start-Sleep -Seconds 2; $p=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if(-not $p){exit 0}; $t=''; try{ $fs=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs.Length -lt $off){$off=0}; if($fs.Length -gt $off){ [void]$fs.Seek($off,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $off=$fs.Length; $sr.Close() } else { $fs.Close() } }catch{ continue }; if(-not ($t -match $env:OC_FATPAT)){ continue }; Start-Sleep -Seconds 4; $t2=''; try{ $fs2=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs2.Length -gt $off){ [void]$fs2.Seek($off,'Begin'); $sr2=New-Object IO.StreamReader($fs2); $t2=$sr2.ReadToEnd(); $off=$fs2.Length; $sr2.Close() } else { $fs2.Close() } }catch{}; $lines=($t+$t2) -split [char]10; $idx=-1; for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match $env:OC_FATPAT){$idx=$i} }; $rec=$false; if($idx -ge 0){ for($j=$idx+1;$j -lt $lines.Count;$j++){ if($lines[$j] -match 'level=(INFO|DEBUG)'){$rec=$true} } }; if($rec){ continue }; $p2=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if($p2){ try{Set-Content -LiteralPath $env:OC_HITF -Value 'HIT'}catch{}; Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$tpid) -WindowStyle Hidden -Wait; exit 1 } }"     
goto :eof

REM Stop the watcher and remove the PID files once the TUI has closed.
:watch_stop
if not exist "%STATE_DIR%\watch.pid" goto :ws_clean
for /f "usebackq delims=" %%p in ("%STATE_DIR%\watch.pid") do taskkill /f /pid %%p >nul 2>&1
del /f /q "%STATE_DIR%\watch.pid" >nul 2>&1
:ws_clean
if exist "%STATE_DIR%\tui.pid" del /f /q "%STATE_DIR%\tui.pid" >nul 2>&1
goto :eof

REM -- scan the log from a byte offset for a fatal pattern ------------
REM usage: call :scan_log <offset>; sets FHIT=1 when the delta matches.
REM Reads the log from the given byte offset and writes HIT or NOHIT to a temp file.
REM The result is read back into FHIT, and the temp file is removed.
:scan_log
set "FHIT="
set "SCANF=%TEMP%\oc_scan_%RANDOM%%RANDOM%.txt"
if exist "%SCANF%" del /f /q "%SCANF%" >nul 2>&1
set "OC_SCANF=%SCANF%"
set "OC_OFF=%~1"
"%PSX%" -NoProfile -Command "try{ $fs=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs.Length -lt [int64]$env:OC_OFF){ Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' } else { [void]$fs.Seek([int64]$env:OC_OFF,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $sr.Close(); if($t -match $env:OC_FATPAT){ Set-Content -LiteralPath $env:OC_SCANF -Value 'HIT' } else { Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' } } }catch{ try{ Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' }catch{} }" >nul 2>&1
if exist "%SCANF%" for /f "usebackq delims=" %%q in ("%SCANF%") do if /i "%%q"=="HIT" set "FHIT=1"
if exist "%SCANF%" del /f /q "%SCANF%" >nul 2>&1
goto :eof

REM -- one probe message on the throwaway session ---------------------
REM exit 0 = the IP can talk, exit 1 = burned or opencode failed.
REM Sends one short message through the proxy to the probe session.
REM Fails if opencode returns an error or the log shows a fatal line.
:probe_once
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "PZB=0"
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "PZB=%%~zS"
call "%OC_CMD%" run -m %PROBE_MODEL% -s %OC_PROBE_ID% --auto "reply with just: ok" >nul 2>&1
set "PEC=%errorlevel%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
call :scan_log %PZB%
if defined FHIT goto :probe_bad
if not "%PEC%"=="0" goto :probe_bad
REM pass: delete the probe session so --continue points at the chat
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
exit /b 0
REM Probe failed: exit with code 1.
:probe_bad
exit /b 1

REM -- locate warp-cli anywhere reasonable ---------------------------
REM Search in order: PATH, then the standard install folders.
REM Sets WARP to the first path found. Leaves it empty if none exists.
:find_warp
set "WARP="
for /f "delims=" %%w in ('where warp-cli.exe 2^>nul') do if not defined WARP set "WARP=%%w"
if defined WARP goto :eof
if exist "%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
REM 32-bit Program Files folder, when it exists.
set "PF86="
if defined ProgramFiles(x86) set "PF86=%ProgramFiles(x86)%"
if defined PF86 if exist "%PF86%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%PF86%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
if defined ProgramW6432 if exist "%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
if exist "%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe"
goto :eof

REM -- one warp-cli call with a hard time limit ----------------------
REM usage: call :wcli registration new
REM A hung call is killed after WARP_CALL_TIMEOUT seconds. Failures
REM are logged to %STATE_DIR%\wcli.log with a timestamp, the exit
REM code and the exact subcommand. Every value travels through the
REM environment, so no path can break the PowerShell command line.
REM Runs one warp-cli command, adds --accept-tos, enforces the timeout, and logs failures.
:wcli
if not defined WARP goto :eof
set "WCMD=%*"
set "OC_EXE=%WARP%"
set "OC_ARGS=--accept-tos %WCMD%"
set "OC_LOG=%STATE_DIR%\wcli.log"
set "OC_TO=%WARP_CALL_TIMEOUT%"
"%PSX%" -NoProfile -Command "$p=Start-Process -FilePath $env:OC_EXE -ArgumentList $env:OC_ARGS -PassThru -WindowStyle Hidden; $null=$p.Handle; if(-not $p.WaitForExit([int]$env:OC_TO*1000)){ try{$p.Kill()}catch{}; try{Add-Content -LiteralPath $env:OC_LOG -Value (((Get-Date -Format o)+' TIMEOUT: '+$env:OC_ARGS))}catch{}; exit 1 }; if($p.ExitCode -ne 0){ try{Add-Content -LiteralPath $env:OC_LOG -Value (((Get-Date -Format o)+' exit '+$p.ExitCode+': '+$env:OC_ARGS))}catch{}; exit $p.ExitCode }; exit 0" >nul 2>&1
if errorlevel 1 echo   [wcli] "%WCMD%" failed - see wcli.log
goto :eof

REM -- install WARP (UAC once) --------------------------------------
REM Downloads the WARP MSI (curl if available, otherwise PowerShell),
REM checks its size, and installs it silently with an elevated msiexec.
REM The proxy variables are cleared during the download and restored afterwards.
:install_warp
set "MSI=%TEMP%\Cloudflare_WARP_x64.msi"
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_URL=%WARP_MSI_URL%"
set "OC_OUT=%MSI%"
echo   downloading the WARP installer, about 60 MB...
if "%HAVE_CURL%"=="1" goto :iw_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
goto :iw_check
REM Download with curl: fail on HTTP errors, 15 minute limit, no proxy.
:iw_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%MSI%" "%WARP_MSI_URL%"
REM Restore the proxy variables and check that the file is larger than 5 MB.
:iw_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "MSIOK=0"
if exist "%MSI%" for %%M in ("%MSI%") do if not "%%~zM"=="" if %%~zM GTR 5000000 set "MSIOK=1"
if "%MSIOK%"=="1" goto :iw_install
echo   [!] download failed.
echo       grab it by hand and run it: %WARP_MSI_URL%
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
goto :eof
REM Install silently; the UAC prompt appears here. Remove the MSI afterwards.
:iw_install
echo   installing, accept the UAC prompt...
set "OC_MSI=%MSI%"
"%PSX%" -NoProfile -Command "try{Start-Process msiexec.exe -ArgumentList '/i',$env:OC_MSI,'/qn' -Verb RunAs -Wait}catch{}" >nul 2>&1
del /f /q "%MSI%" >nul 2>&1
goto :eof

REM -- install opencode: npm when present, else the standalone build --
REM If opencode is already in its standard folder, do nothing.
REM Try npm first. If npm fails, fall back to the standalone zip.
:install_opencode
if exist "%LOCALAPPDATA%\opencode\bin\opencode.exe" goto :eof
where npm >nul 2>&1
if errorlevel 1 goto :standalone
call :npm_install
call :find_opencode
if defined OC_CMD goto :eof
echo   [auto-install] npm did not deliver it, going standalone.

REM Standalone build. Chooses x64 or arm64; 32-bit systems are not supported.
:standalone
set "OCARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "OCARCH=arm64"
if not "%REAL86%"=="1" goto :sa_ok
echo   [!] 32-bit Windows: opencode publishes x64 and arm64 builds only.
echo       The standalone download will not run here.
REM On 32-bit, the only option left is npm with 32-bit node.
where npm >nul 2>&1
if not errorlevel 1 (
  echo       npm exists - trying it...
  call :npm_install
  call :find_opencode
  if defined OC_CMD goto :eof
)
echo   ERROR: opencode cannot be auto-installed on 32-bit Windows.
echo          Install 32-bit node.js, then run: npm i -g opencode-ai
pause
goto :quit

REM Download the standalone zip from the latest GitHub release.
:sa_ok
set "OC_URL=https://github.com/sst/opencode/releases/latest/download/opencode-windows-%OCARCH%.zip"
set "OCZIP=%TEMP%\opencode-windows.zip"
set "OCBIN=%LOCALAPPDATA%\opencode\bin"
echo   [auto-install] downloading the standalone build...
echo     %OC_URL%
if exist "%OCZIP%" del /f /q "%OCZIP%" >nul 2>&1
REM Clear the proxy during the download, as in install_warp.
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_OUT=%OCZIP%"
if "%HAVE_CURL%"=="1" goto :sa_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
goto :sa_check
REM Download with curl, as in install_warp.
:sa_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%OCZIP%" "%OC_URL%"
REM Restore the proxy and check that the zip is larger than 5 MB.
:sa_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "ZOK=0"
if exist "%OCZIP%" for %%Z in ("%OCZIP%") do if not "%%~zZ"=="" if %%~zZ GTR 5000000 set "ZOK=1"
if "%ZOK%"=="1" goto :sa_unzip
echo     [!] download failed.
if exist "%OCZIP%" del /f /q "%OCZIP%" >nul 2>&1
goto :eof
REM Unpack the zip into the bin folder, then add that folder to PATH for this session.
:sa_unzip
if not exist "%OCBIN%" mkdir "%OCBIN%" >nul 2>&1
echo   [auto-install] unpacking, about 200 MB on disk...
set "OC_ZIP=%OCZIP%"
set "OC_BIN=%OCBIN%"
"%PSX%" -NoProfile -Command "try{Expand-Archive -LiteralPath $env:OC_ZIP -DestinationPath $env:OC_BIN -Force}catch{}" >nul 2>&1
del /f /q "%OCZIP%" >nul 2>&1
set "PATH=%PATH%;%OCBIN%"
if exist "%OCBIN%\opencode.exe" echo   [ok] installed to %OCBIN%
goto :eof

REM Install opencode with npm globally, then add the npm folder to PATH for this session.
:npm_install
echo   [auto-install] installing with npm...
call npm install -g opencode-ai
set "PATH=%PATH%;%APPDATA%\npm"
goto :eof

REM -- locate opencode anywhere reasonable --------------------------
REM Search PATH first (exe, cmd, bat), then the usual install folders.
REM Sets OC_CMD to the first path found.
:find_opencode
set "OC_CMD="
for /f "delims=" %%o in ('where opencode.exe 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD for /f "delims=" %%o in ('where opencode.cmd 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD for /f "delims=" %%o in ('where opencode.bat 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD if exist "%APPDATA%\npm\opencode.cmd" set "OC_CMD=%APPDATA%\npm\opencode.cmd"
if not defined OC_CMD if exist "%LOCALAPPDATA%\Programs\opencode\opencode.exe" set "OC_CMD=%LOCALAPPDATA%\Programs\opencode\opencode.exe"
if not defined OC_CMD if exist "%LOCALAPPDATA%\opencode\bin\opencode.exe" set "OC_CMD=%LOCALAPPDATA%\opencode\bin\opencode.exe"
if not defined OC_CMD if exist "%USERPROFILE%\.opencode\bin\opencode.exe" set "OC_CMD=%USERPROFILE%\.opencode\bin\opencode.exe"
goto :eof

REM -- WARP into WireGuard + proxy mode on port 40000 and connected --
REM Sets the tunnel protocol to MASQUE, switches to proxy mode on
REM PROXY_PORT, then connects. Waits 3 seconds for the connection.
:warp_up
call :wcli tunnel protocol set MASQUE
call :wcli mode proxy
call :wcli proxy port %PROXY_PORT%
call :wcli connect
timeout /t 3 /nobreak >nul 2>&1
goto :eof

REM -- exit IP + warp flag -------------------------------------------
REM When WARP is on, an IP is reported only if the trace came back
REM through the proxy AND says warp=on. a dead tunnel reports nothing,
REM never the real IP dressed up as a fresh one.
REM Returns the exit IP in the variable named by argument 1 and the
REM warp flag in the variable named by argument 2.
REM Tries the HTTP proxy first, then SOCKS5, when WARP is on.
REM Without WARP it reads the IP directly.
:getip2
set "%~1="
set "%~2="
set "GIP="
set "GFLAG="
if not defined WARP goto :getip2_direct
set "TFILE=%TEMP%\oc_trace_%RANDOM%.txt"
set "OC_TURL=%TRACE_URL%"
set "OC_TFILE=%TFILE%"
set "OC_TPROXY=%PROXY%"
if "%HAVE_CURL%"=="1" goto :gip_curl_http
REM PowerShell fallback: read the trace through the proxy and write it to a file.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; (Invoke-RestMethod -Uri $env:OC_TURL -Proxy $env:OC_TPROXY -TimeoutSec 8) -replace [char]13,[char]10 | Out-File -LiteralPath $env:OC_TFILE -Encoding ascii}catch{}" >nul 2>&1
goto :gip_parse
REM curl through the HTTP proxy. If the file is empty, try the SOCKS5 proxy.
:gip_curl_http
curl.exe -4 -s -f --max-time 8 -x "%PROXY%" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1
if exist "%TFILE%" for %%T in ("%TFILE%") do if %%~zT GTR 0 goto :gip_parse
curl.exe -4 -s -f --max-time 8 -x "%SOCKS_PROXY%" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1
goto :gip_parse

REM Without WARP: read the IP directly, with proxies ignored.
:getip2_direct
set "TFILE=%TEMP%\oc_trace_%RANDOM%.txt"
set "OC_TURL=%TRACE_URL%"
set "OC_TFILE=%TFILE%"
if "%HAVE_CURL%"=="1" goto :gid_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; (Invoke-RestMethod -Uri $env:OC_TURL -TimeoutSec 10) -replace [char]13,[char]10 | Out-File -LiteralPath $env:OC_TFILE -Encoding ascii}catch{}" >nul 2>&1
goto :gip_parse
REM curl without any proxy.
:gid_curl
curl.exe -4 -s -f --max-time 10 --noproxy "*" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1

REM Read the ip= and warp= lines from the trace file, then delete it.
REM With WARP on, a result that is not warp=on is discarded.
:gip_parse
if not exist "%TFILE%" goto :gip_done
for /f "tokens=2 delims==" %%i in ('findstr /b "ip=" "%TFILE%"') do set "GIP=%%i"
for /f "tokens=2 delims==" %%w in ('findstr /b "warp=" "%TFILE%"') do set "GFLAG=%%w"
del /f /q "%TFILE%" >nul 2>&1
:gip_done
if not defined WARP goto :gip_store
if not "%GFLAG%"=="on" set "GIP="
REM Return the values through the caller variable names.
:gip_store
if defined GIP set "%~1=%GIP%"
if defined GFLAG set "%~2=%GFLAG%"
goto :eof

REM -- make sure this launch does not reuse the last egress IP ------
REM Compares the current IP with lastip.txt. If they match, it asks
REM WARP for a new registration, up to ROTATE_TRIES_MAX times.
REM After the limit, it keeps the current IP and continues.
:ensure_new_ip
set "LASTIP="
if exist "%STATE_DIR%\lastip.txt" set /p LASTIP=<"%STATE_DIR%\lastip.txt"
call :getip2 CUR CFLAG
if defined CUR if /i "%CFLAG%"=="on" goto :ens_have
echo   WARP proxy is not answering - cannot verify the exit IP.
goto :eof
REM Current IP is verified: compare it with the last one.
:ens_have
if not defined LASTIP goto :remember_ip
if /i not "%CUR%"=="%LASTIP%" goto :remember_ip
echo   same IP as the last run, requesting a new registration...
set /a EN_TRIES=0

REM Loop: new registration until the IP differs or the limit is reached.
:ens_loop
set /a EN_TRIES+=1
if %EN_TRIES% GTR %ROTATE_TRIES_MAX% goto :ens_giveup
echo   [%EN_TRIES%] disconnect...
call :wcli disconnect
echo   [%EN_TRIES%] deleting old registration...
call :wcli registration delete
timeout /t 1 /nobreak >nul 2>&1
echo   [%EN_TRIES%] new registration...
call :wcli registration new
timeout /t 1 /nobreak >nul 2>&1
echo   [%EN_TRIES%] reconnecting WARP proxy...
call :warp_up
set "WARP_UP=1"
echo   [%EN_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 CUR CFLAG
if not defined CUR goto :ens_loop
if not "%CFLAG%"=="on" goto :ens_loop
if /i "%CUR%"=="%LASTIP%" goto :ens_loop

REM Save the IP as the last one used and show it.
:remember_ip
if defined CUR if /i "%CFLAG%"=="on" >"%STATE_DIR%\lastip.txt" echo %CUR%
set "IP=%CUR%"
echo   exit IP: %CUR%
goto :eof
REM Limit reached without a new IP: continue with the current one.
:ens_giveup
echo   no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.
goto :remember_ip

REM -- did this run write a fatal line to the log? -------------------
REM Sets QHIT=1 when the log part written during this run has a fatal line.
REM If the log does not exist, warns once and leaves auto-detection off.
:check_quota
set "QHIT="
if exist "%LOGFILE%" goto :cq_run
if defined QWARNED goto :eof
set "QWARNED=1"
echo   [note] opencode log not found: "%LOGFILE%"
echo          auto-detect stays off until the log appears.
goto :eof
REM Scan the log from the size recorded before launch.
:cq_run
call :scan_log %SIZE_BEFORE%
if defined FHIT set "QHIT=1"
goto :eof

REM -- close every opencode process so the chat db unlocks ------------
REM Ask opencode to stop its service, then kill any remaining processes.
REM The short wait lets the database files unlock before they are moved.
:stop_opencode
if defined OC_CMD call "%OC_CMD%" service stop >nul 2>&1
taskkill /f /im "OpenCode.exe" >nul 2>&1
taskkill /f /im "opencode.exe" >nul 2>&1
taskkill /f /im "opencode-cli.exe" >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
goto :eof

REM -- the desktop can be redirected to OneDrive or another drive ----
REM Asks PowerShell for the real Desktop folder. If that fails, falls back
REM to OneDrive\Desktop, then Desktop, then the user profile folder.
:find_desktop
set "DESKTOP="
set "OC_OUT=%TEMP%\oc_dsk_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_DSK=%OC_OUT%"
"%PSX%" -NoProfile -Command "try{[IO.File]::WriteAllLines($env:OC_DSK, [Environment]::GetFolderPath('Desktop'))}catch{}" >nul 2>&1
if exist "%OC_OUT%" for /f "usebackq delims=" %%D in ("%OC_OUT%") do set "DESKTOP=%%D"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
if defined DESKTOP if not exist "%DESKTOP%\" set "DESKTOP="
if not defined DESKTOP if exist "%USERPROFILE%\OneDrive\Desktop" set "DESKTOP=%USERPROFILE%\OneDrive\Desktop"
if not defined DESKTOP if exist "%USERPROFILE%\Desktop" set "DESKTOP=%USERPROFILE%\Desktop"
if not defined DESKTOP set "DESKTOP=%USERPROFILE%"
goto :eof

REM -- move the chats out of the way, timestamped, never overwritten --
REM Creates a timestamped folder on the Desktop and moves the chat database
REM and storage folder into it. The stamp comes from PowerShell, with a random
REM fallback. MOVED stays 0 when nothing was moved, and the empty folder is removed.
:deep_archive
if not defined DESKTOP call :find_desktop
set "ARCHIVE_ROOT=%DESKTOP%\opencode_chats_archiviate"
set "STAMP="
set "OC_OUT=%TEMP%\oc_stm_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_STM=%OC_OUT%"
"%PSX%" -NoProfile -Command "try{[IO.File]::WriteAllLines($env:OC_STM, (Get-Date -Format yyyyMMdd-HHmmss))}catch{}" >nul 2>&1
if exist "%OC_OUT%" for /f "usebackq delims=" %%T in ("%OC_OUT%") do set "STAMP=%%T"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
if not defined STAMP set "STAMP=r%RANDOM%%RANDOM%"
set "TARGET=%ARCHIVE_ROOT%\%STAMP%"
echo   archiving chats to:
echo     "%TARGET%"
set "MOVED=0"
if exist "%DATA_DIR%\storage" call :archive_storage
for %%F in (opencode.db opencode.db-wal opencode.db-shm) do call :archive_file %%F
if not "%MOVED%"=="0" goto :arch_done
if exist "%TARGET%" rmdir "%TARGET%" >nul 2>&1
echo   nothing to archive.
goto :eof
REM Something was moved: report it.
:arch_done
echo   archived.
goto :eof

REM robocopy does not care about volumes and deletes the source
REM only after the copy is complete.
REM Move the storage folder with robocopy. Exit codes 8 and above mean failure.
:archive_storage
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
robocopy "%DATA_DIR%\storage" "%TARGET%\storage" /e /move /r:1 /w:1 /nfl /ndl /njh /njs /np >nul
if errorlevel 8 (
  echo   [!] could not move the storage folder - it stays where it is.
  goto :eof
)
set "MOVED=1"
goto :eof

REM copy first, verify the size, delete only then.
REM Copy one database file, compare the sizes, and delete the original only if they match.
:archive_file
if not exist "%DATA_DIR%\%1" goto :eof
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
copy /y "%DATA_DIR%\%1" "%TARGET%\%1" >nul
if errorlevel 1 (
  echo   [!] could not copy %1 - it stays where it is.
  goto :eof
)
set "SZS="
set "SZD="
for %%A in ("%DATA_DIR%\%1") do set "SZS=%%~zA"
for %%A in ("%TARGET%\%1") do set "SZD=%%~zA"
if "%SZS%"=="%SZD%" goto :af_del
echo   [!] size mismatch on %1 - the bad copy is deleted, the original stays.
del /f /q "%TARGET%\%1" >nul 2>&1
goto :eof
REM Sizes match: delete the original and count the file as moved.
:af_del
del /f /q "%DATA_DIR%\%1" >nul 2>&1
set "MOVED=1"
goto :eof

REM -- cache and saved tokens ----------------------------------------
REM Delete the opencode cache folder and the saved login file (auth.json).
REM Chats in the database are not touched here.
:clear_tokens
set "CACHE_DIR=%USERPROFILE%\.cache\opencode"
if exist "%CACHE_DIR%" rmdir /s /q "%CACHE_DIR%" >nul 2>&1
if exist "%DATA_DIR%\auth.json" del /f /q "%DATA_DIR%\auth.json" >nul 2>&1
echo   cache and tokens cleared.
goto :eof

REM -- hand the WARP proxy to the child process only -----------------
REM Returns errorlevel 1 when the proxy is dead; the caller decides.
REM Sets HTTP_PROXY, HTTPS_PROXY and no_proxy so that child processes use the proxy.
:export_proxy
if not defined WARP goto :eof
call :proxy_ok
if errorlevel 1 exit /b 1
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "no_proxy=%NO_PROXY%"
exit /b 0

REM -- can the proxy actually carry an https request? ----------------
REM With curl: try the HTTP proxy, then SOCKS5. Without curl: only check
REM that the port accepts a TCP connection (the 1.5 second wait).
:proxy_ok
if not "%HAVE_CURL%"=="1" goto :proxy_ok_tcp
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 exit /b 0
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%SOCKS_PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 exit /b 0
exit /b 1

REM TCP-only check, used when curl is missing.
:proxy_ok_tcp
"%PSX%" -NoProfile -Command "try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',%PROXY_PORT%,$null,$null);if(-not $a.AsyncWaitHandle.WaitOne(1500)){exit 1};$c.EndConnect($a);$c.Close();exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

REM -- one launcher at a time -----------------------------------------
REM The lock is a folder: creating it succeeds only for the first launcher.
REM A lock older than 2 hours is treated as stale and removed. A newer lock
REM triggers a question: continue anyway, or exit.
:lock_check
set "LOCKDIR=%STATE_DIR%\lock"
md "%LOCKDIR%" >nul 2>&1
if not errorlevel 1 goto :eof
set "OC_LOCK=%LOCKDIR%"
REM Remove the lock if it is older than 2 hours (exit 0 means stale and removed).
"%PSX%" -NoProfile -Command "try{$i=Get-Item -LiteralPath $env:OC_LOCK -Force;if(((Get-Date)-$i.LastWriteTime).TotalHours -gt 2){Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force;exit 0}else{exit 1}}catch{exit 0}" >nul 2>&1
if not errorlevel 1 goto :lock_retry
echo   [!] Another OpenCode launcher seems to be running.
choice /c YN /n /m "   Continue anyway? [Y/N]: "
if errorlevel 2 goto :quit_busy
rmdir /s /q "%LOCKDIR%" >nul 2>&1
md "%LOCKDIR%" >nul 2>&1
goto :eof
REM Stale lock removed: create a new one.
:lock_retry
md "%LOCKDIR%" >nul 2>&1
goto :eof
REM User chose not to continue: exit.
:quit_busy
echo   Exiting.
timeout /t 2 /nobreak >nul 2>&1
goto :quit

REM -- keep the settings numeric (0 allowed only for numcfg0) ---------
REM Accepts only numbers of at least 1. Anything else falls back to the default.
REM A default is set first when the variable is empty.
:numcfg
if not defined %1 set "%1=%~2"
call set "NCV=%%%1%%"
set "NCN="
set /a NCN=NCV 2>nul
if not defined NCN set "NCN=%~2"
if %NCN% LSS 1 set "NCN=%~2"
set "%1=%NCN%"
goto :eof
REM Same as numcfg, but accepts 0 as a valid value.
:numcfg0
if not defined %1 set "%1=%~2"
call set "NCV=%%%1%%"
set "NCN="
set /a NCN=NCV 2>nul
if not defined NCN set "NCN=%~2"
if %NCN% LSS 0 set "NCN=%~2"
set "%1=%NCN%"
goto :eof

REM Common exit: restore the folder with popd, remove the lock, and end the local scope.
:quit
if defined POPPED popd
if exist "%STATE_DIR%\lock\" rmdir /s /q "%STATE_DIR%\lock" >nul 2>&1
endlocal