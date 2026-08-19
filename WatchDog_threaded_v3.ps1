#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Watches one or more process names. Runs a command against every existing
    instance at startup, then again on every future spawn. The command blocks
    on a Windows "Press any key to continue" prompt; before injecting the key
    we pull this console to the foreground, so it still works if you have
    clicked away to another window.

.DESCRIPTION
    Two phases:
      1. Pre-flight sweep: Get-Process fires your command against every instance
         of every named process already running.
      2. Watchdog: a single Win32_ProcessStartTrace subscription (all names OR'd
         into one WQL query) fires it on every new spawn.

    Spawns are handled ONE AT A TIME, so concurrent "press any key" prompts
    never fight over the shared console input buffer.

    Feeding the key: a background thread waits a moment, brings this console
    window to the foreground (via GetConsoleWindow + an AttachThreadInput focus
    grab, since Windows resists background focus-stealing), then writes a real
    Enter into the console input buffer with WriteConsoleInput. SendKeys is not
    used because the prompt reads the input buffer, not window messages.

    NOTE ON WINDOWS TERMINAL: under ConPTY, GetConsoleWindow returns a hidden
    window, so the foreground pull cannot raise the real Terminal tab. If the
    focus grab does nothing for you, run the script in a classic console host
    window (e.g. launch powershell.exe directly) rather than Windows Terminal.

    Requires an elevated session (reading the process-start trace is privileged).

.PARAMETER ProcessName
    One or more process names, e.g. "notepad" or "notepad","calc","mspaint".
    The .exe suffix is added automatically where omitted.

.EXAMPLE
    .\Watch-Process.ps1 -ProcessName notepad,calc,mspaint
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ProcessName
)

# Normalise into a list of full image names ("notepad" -> "notepad.exe").
$targets = @($ProcessName | ForEach-Object {
    if ($_ -match '\.exe$') { $_ } else { $_ + '.exe' }
})

# --- Console helper: focus this window, then inject a real Enter ------------
if (-not ('Conio' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class Conio
{
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEY_EVENT_RECORD
    {
        [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public ushort UnicodeChar;
        public uint   dwControlKeyState;
    }

    const uint   GENERIC_READ  = 0x80000000;
    const uint   GENERIC_WRITE = 0x40000000;
    const uint   FILE_SHARE_RW = 0x00000003;
    const uint   OPEN_EXISTING = 3;
    const ushort KEY_EVENT     = 1;
    const ushort VK_RETURN     = 0x0D;
    const int    SW_RESTORE    = 9;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern uint   GetCurrentThreadId();
    [DllImport("user32.dll")]   static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]   static extern uint   GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]   static extern bool   AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]   static extern bool   SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]   static extern bool   BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]   static extern bool   ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   static extern bool   IsIconic(IntPtr hWnd);

    // Bring THIS script's console window to the foreground, fighting past
    // Windows' anti-focus-stealing by briefly attaching to the current
    // foreground thread's input queue.
    public static void FocusConsole()
    {
        IntPtr hWnd = GetConsoleWindow();
        if (hWnd == IntPtr.Zero) return;

        if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);

        uint pid;
        uint fgThread   = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint thisThread = GetCurrentThreadId();

        if (fgThread != thisThread) AttachThreadInput(fgThread, thisThread, true);
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        if (fgThread != thisThread) AttachThreadInput(fgThread, thisThread, false);
    }

    // Put one Enter (key down + key up) into the console input buffer now.
    public static void SendEnter()
    {
        IntPtr h = CreateFile("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                              IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == (IntPtr)(-1)) return;

        var recs = new INPUT_RECORD[2];
        recs[0].EventType = KEY_EVENT;
        recs[0].KeyEvent.bKeyDown        = true;
        recs[0].KeyEvent.wRepeatCount    = 1;
        recs[0].KeyEvent.wVirtualKeyCode = VK_RETURN;
        recs[0].KeyEvent.UnicodeChar     = 13;
        recs[1] = recs[0];
        recs[1].KeyEvent.bKeyDown = false;

        uint written;
        WriteConsoleInput(h, recs, 2, out written);
        CloseHandle(h);
    }

    // Background thread: after a delay, pull the console to the foreground,
    // let the focus switch settle, then inject Enter. Focusing first is what
    // lets it still work when you have clicked away to another window.
    public static void SendEnterAfter(int delayMs)
    {
        var t = new Thread(() => {
            Thread.Sleep(delayMs);
            FocusConsole();
            Thread.Sleep(120);
            SendEnter();
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@
}

# --------------------------------------------------------------------------
#  The one and only place your command lives. Edited once, used by every
#  process name and both phases. $Name is which process fired; $TargetPid is
#  its PID.
# --------------------------------------------------------------------------
function Invoke-Target {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TargetPid,
        [int]$ParentPid = -1
    )

    $parentText = if ($ParentPid -ge 0) { $ParentPid } else { 'n/a' }
    Write-Host ("[{0}] {1}  PID={2}  Parent={3}" -f (Get-Date -Format 'HH:mm:ss'), $Name, $TargetPid, $parentText)

    # Schedule the Enter to land ~600ms in, on a background thread: it pulls
    # this console to the foreground, then injects. If your tool is slow to
    # reach the prompt, raise this number.
    [Conio]::SendEnterAfter(600)

    # ======================================================================
    #  YOUR COMMAND (blocks at "Press any key", then exits once Enter lands).
    #  $TargetPid holds the PID, $Name holds the process name. (Do NOT use $PID.)
    # ======================================================================
    & "C:\Users\user\BYOVD\UsingBYOVD\x64\Debug\UsingBYOVD.exe" --K $TargetPid

    # ======================================================================
}

# --- Phase 1: pre-flight sweep of anything already running ------------------
$anyFound = $false
foreach ($t in $targets) {
    $base = $t -replace '\.exe$', ''
    $existing = @(Get-Process -Name $base -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $anyFound = $true
        Write-Host ("Found {0} running instance(s) of '{1}'. Firing now." -f $existing.Count, $t) -ForegroundColor Green
        foreach ($p in $existing) { Invoke-Target -Name $t -TargetPid $p.Id }
    }
}
if (-not $anyFound) {
    Write-Host "No running instances of the target process(es) at startup. Going straight to watch mode." -ForegroundColor DarkGray
}

# --- Phase 2: register the watchdog (all names in one OR'd query) -----------
$sourceId    = "ProcWatch"
$whereClause = ($targets | ForEach-Object { "ProcessName = '$_'" }) -join ' OR '
$query       = "SELECT * FROM Win32_ProcessStartTrace WHERE $whereClause"

Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
Remove-Event     -SourceIdentifier $sourceId -ErrorAction SilentlyContinue

Register-CimIndicationEvent -Query $query -SourceIdentifier $sourceId | Out-Null

try {
    while ($true) {
        Write-Host ("Watching for spawns of: {0}. Press Ctrl+C to stop." -f ($targets -join ', ')) -ForegroundColor Cyan

        # One queue for all names. Handled one at a time, in arrival order.
        $evt = Wait-Event -SourceIdentifier $sourceId

        $newEvent    = $evt.SourceEventArgs.NewEvent
        $spawnedName = [string]$newEvent.ProcessName
        $spawnedPid  = $newEvent.ProcessID
        $parentPid   = $newEvent.ParentProcessID

        Remove-Event -EventIdentifier $evt.EventIdentifier

        Invoke-Target -Name $spawnedName -TargetPid $spawnedPid -ParentPid $parentPid
    }
}
finally {
    Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    Remove-Event     -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    Write-Host "`nWatchdog stopped. Subscription cleaned up." -ForegroundColor Yellow
}