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
    [string[]]$ProcessName,

    # Switch off the whack-a-mole animation entirely (for serious/quiet runs).
    [switch]$NoAnimation
)

# Normalise into a list of full image names ("notepad" -> "notepad.exe").
$targets = @($ProcessName | ForEach-Object {
    if ($_ -match '\.exe$') { $_ } else { $_ + '.exe' }
})

# Session-persistent whack-a-mole kill counter. Show-Bonk increments and
# displays it after each target is dealt with; it survives every spawn for
# the life of the script.
$script:BonkScore = 0

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

# --------------------------------------------------------------------------
#  Show-Bonk: a purely cosmetic ASCII whack-a-mole. Called from the watch
#  loop AFTER Invoke-Target has returned (command run, process dealt with) -
#  never before or during. It runs on the MAIN thread only; the Enter
#  keystroke is delivered by an independent background thread scheduled inside
#  Invoke-Target ([Conio]::SendEnterAfter), so nothing here can shift that
#  timing. The whole body is wrapped in try/catch: if the animation ever
#  fails it is swallowed and the watchdog keeps running. Pass the whacked
#  process Name and PID for the scoreboard, and (optionally) the event
#  SourceIdentifier so we can fast-forward and return promptly when another
#  spawn is already queued.
# --------------------------------------------------------------------------
function Show-Bonk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TargetPid,
        [string]$SourceIdentifier
    )

    $artW = 40
    $artH = 16
    $origFg       = $null
    $origVis      = $true
    $anchorTop    = 0
    $cursorHidden = $false

    try {
        # --- Fit check: if the window is too small, skip (never throw/garble).
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -lt ($artW + 2) -or $h -lt ($artH + 2)) { return }

        $startX = [int](($w - $artW) / 2)
        if ($startX -lt 0) { $startX = 0 }

        $origFg = [Console]::ForegroundColor
        try { $origVis = [Console]::CursorVisible } catch { $origVis = $true }
        [Console]::CursorVisible = $false
        $cursorHidden = $true

        # Reserve artH rows below the cursor so frame drawing never scrolls the
        # buffer mid-animation. Writing the newlines does any scrolling now, once.
        [Console]::Write([Environment]::NewLine * $artH)
        $anchorTop = [Console]::CursorTop - $artH
        if ($anchorTop -lt 0) { $anchorTop = 0 }

        # ---- tiny flicker-free drawing kit (nested; reads the vars above) ----
        function Merge([string]$base, [string]$over) {
            $b = $base.PadRight($artW).Substring(0, $artW).ToCharArray()
            $o = $over.PadRight($artW)
            for ($i = 0; $i -lt $artW; $i++) { if ($o[$i] -ne ' ') { $b[$i] = $o[$i] } }
            return (-join $b)
        }
        function New-Base {
            $c = [string[]]::new($artH)
            for ($i = 0; $i -lt $artH; $i++) { $c[$i] = ' ' * $artW }
            $c[12] = ('_' * 16) + (' ' * 8) + ('_' * 16)
            $c[13] = ('#' * 16) + (' ' * 8) + ('#' * 16)
            return ,$c
        }
        function Place($canvas, $lines, [int]$top) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $r = $top + $i
                if ($r -ge 0 -and $r -lt $artH) { $canvas[$r] = Merge $canvas[$r] $lines[$i] }
            }
        }
        function Draw($frame, $color) {
            if ($null -ne $color) { [Console]::ForegroundColor = $color }
            for ($i = 0; $i -lt $artH; $i++) {
                $line = if ($i -lt $frame.Count) { [string]$frame[$i] } else { '' }
                if ($line.Length -gt $artW) { $line = $line.Substring(0, $artW) } else { $line = $line.PadRight($artW) }
                [Console]::SetCursorPosition($startX, $anchorTop + $i)
                [Console]::Write($line)
            }
            if ($null -ne $color) { [Console]::ForegroundColor = $origFg }
        }
        function Pending {
            if ([string]::IsNullOrEmpty($SourceIdentifier)) { return $false }
            return ((@(Get-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue)).Count -gt 0)
        }
        function Nap([int]$ms) { Start-Sleep -Milliseconds $ms }

        # ---- sprites (single-quoted: every char is literal) ------------------
        #  ruler ->   0123456789012345678901234567890123456789
        $headTop = '               .------.                 '
        $eyesC   = '              /  o  o  \                 '
        $eyesL   = '              / o  o   \                 '
        $eyesR   = '              /   o  o \                 '
        $eyesX   = '              /  x  x  \                 '
        $snout   = '              |  (..)  |                 '
        $mouth   = '              \  \__/  /                 '
        $mouthZ  = '              \  ~~~~  /                 '
        $baseRow = '               \______/                 '

        $moleC = @($headTop, $eyesC, $snout, $mouth,  $baseRow)
        $moleZ = @($headTop, $eyesX, $snout, $mouthZ, $baseRow)
        $peekC = @($headTop, $eyesC)
        $peekL = @($headTop, $eyesL)
        $peekR = @($headTop, $eyesR)

        $hammer = @(
            '           +==============+             ',
            '           |    B O N K   |             ',
            '           +==============+             ',
            '                 ||                     ',
            '                 ||                     '
        )
        $impact = @('            \    *   *    /              ')
        $burst  = @(
            '             \    |    /                 ',
            '          *    \  |  /    *              ',
            '           ---- ( >< ) ----              ',
            '          *    /  |  \    *              ',
            '             /    |    \                 '
        )

        # ---- speech-bubble builder (guaranteed-aligned via PadRight) ---------
        function Bubble([string]$text) {
            $inner = 30
            if ($text.Length -gt $inner) { $text = $text.Substring(0, $inner) }
            $top   = '  .' + ('-' * ($inner + 2)) + '.'
            $mid   = '  | ' + $text.PadRight($inner) + ' |'
            $bot   = '  `' + ('-' * ($inner + 2)) + '`'
            $tail1 = '              \                         '
            $tail2 = '               \                        '
            return @($top, $mid, $bot, $tail1, $tail2)
        }

        # =====================================================================
        #  BEAT 1 - PEEK: wary emergence, a glance left, a glance right.
        # =====================================================================
        $f = New-Base;                     Draw $f $null; Nap 250   # empty hole
        $f = New-Base; Place $f $peekC 10; Draw $f $null; Nap 420   # eyes up, wary
        $f = New-Base; Place $f $peekL 10; Draw $f $null; Nap 520   # look left
        $f = New-Base; Place $f $peekR 10; Draw $f $null; Nap 520   # look right
        $f = New-Base; Place $f $peekC 10; Draw $f $null; Nap 260
        $f = New-Base; Place $f $moleC  9; Draw $f $null; Nap 130   # rise...
        $f = New-Base; Place $f $moleC  8; Draw $f $null; Nap 130
        $f = New-Base; Place $f $moleC  7; Draw $f $null; Nap 200   # ...fully up

        $fast = Pending

        # =====================================================================
        #  BEAT 2 - EXISTENTIAL CRISIS: milked, one line at a time.
        # =====================================================================
        $dialogue = @(
            'Ah. The surface. We meet again.'
            "I've been alive four seconds now."
            'Statistically, I am a process.'
            'Something up here knows my PID.'
            'It has a hammer. It always does.'
            'I am watched, therefore I am.'
            'Another me will rise in a minute,'
            'certain it is the very first mole.'
            '...still. Perhaps today is diff-'
        )
        foreach ($line in $dialogue) {
            if (-not $fast -and (Pending)) { $fast = $true }
            $f = New-Base
            Place $f (Bubble $line) 0
            Place $f $moleC 7
            Draw $f $null
            if ($fast) { Nap 140; break } else { Nap 900 }
        }

        # =====================================================================
        #  BEAT 3 - WIND-UP: the hammer rises over three frames, ominously.
        # =====================================================================
        $wu = if ($fast) { 60 } else { 250 }
        $f = New-Base; Place $f $moleC 7; Place $f $hammer 2; Draw $f $null; Nap $wu
        $f = New-Base; Place $f $moleC 7; Place $f $hammer 1; Draw $f $null; Nap $wu
        $f = New-Base; Place $f $moleC 7; Place $f $hammer 0; Draw $f $null; Nap ($wu + 150)

        # =====================================================================
        #  BEAT 4 - BONK: slam, impact, splat. In red.
        # =====================================================================
        $script:BonkScore++
        $f = New-Base; Place $f $moleZ 7; Place $f $hammer 5; Place $f $impact 4
        Draw $f ([ConsoleColor]::Red); if ($fast) { Nap 150 } else { Nap 380 }
        $f = New-Base; Place $f $burst 7
        Draw $f ([ConsoleColor]::Red); if ($fast) { Nap 160 } else { Nap 430 }

        # =====================================================================
        #  BEAT 5 - SCORE: session-persistent counter + the named victim.
        # =====================================================================
        $score = @(
            ('   +' + ('=' * 30) + '+'),
            ('   |' + '         W H A C K !'.PadRight(30).Substring(0, 30) + '|'),
            ('   |' + ("  moles bonked : " + [string]$script:BonkScore).PadRight(30).Substring(0, 30) + '|'),
            ('   |' + ("  process : " + $Name).PadRight(30).Substring(0, 30) + '|'),
            ('   |' + ("  PID     : " + [string]$TargetPid).PadRight(30).Substring(0, 30) + '|'),
            ('   +' + ('=' * 30) + '+')
        )
        $f = New-Base; Place $f $burst 7; Place $f $score 0
        Draw $f ([ConsoleColor]::Yellow); if ($fast) { Nap 500 } else { Nap 1500 }
    }
    catch {
        # Cosmetic only: never let the animation take down the watchdog.
    }
    finally {
        try { if ($null -ne $origFg) { [Console]::ForegroundColor = $origFg } } catch {}
        try { if ($cursorHidden) { [Console]::CursorVisible = $origVis } } catch {}
        # Park the cursor just below the art so the next log line stays clean.
        try { [Console]::SetCursorPosition(0, [Math]::Min($anchorTop + $artH, [Console]::BufferHeight - 1)) } catch {}
    }
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

        # The process has now been dealt with (command run, key delivered).
        # Play the whack-a-mole ONLY here, after Invoke-Target has returned -
        # never before or during. It runs on this (main) thread; the Enter
        # keystroke was scheduled onto its own background thread inside
        # Invoke-Target, so this animation cannot shift that timing. If another
        # spawn is already queued, Show-Bonk fast-forwards and returns promptly
        # so we get straight back to Wait-Event without blocking real work.
        if (-not $NoAnimation) {
            Show-Bonk -Name $spawnedName -TargetPid $spawnedPid -SourceIdentifier $sourceId
        }
    }
}
finally {
    # Restore the cursor in case we were interrupted (Ctrl+C) mid-animation
    # with it hidden. Guarded so a headless/redirected host can't throw here.
    try { [Console]::CursorVisible = $true } catch {}

    Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    Remove-Event     -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    Write-Host "`nWatchdog stopped. Subscription cleaned up." -ForegroundColor Yellow
}