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

# Per-process mole registry: each distinct process name is given, once, a
# stable hole (screen column) and mole face for the whole session, so
# interleaved names stay visually distinct. Populated lazily by Show-Bonk.
$script:MoleReg  = @{}
$script:MoleNext = 0

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
#  fails it is swallowed and the watchdog keeps running.
#
#  Each distinct process name is assigned - once, stably, for the session -
#  its own hole (a fixed screen column) and its own mole face, so different
#  processes are told apart by where they pop up and how they look, even when
#  they interleave. The mole blurts ONE random line and is promptly whacked
#  by a sideways hammer - facing left or right, chosen at random - that
#  swings down and clobbers it. Pass the
#  whacked process Name and PID for the scoreboard, and (optionally) the
#  event SourceIdentifier so we can fast-forward when another spawn is queued.
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

    # Holes (screen columns) and mole faces. A process name keeps the same
    # slot + face for the whole session, so interleaved names stay distinct.
    $slots      = @(8, 16, 24, 32)
    $styleEyes  = @('  o o  ', ' -o-o- ', '  >_<  ', '  O O  ', '  u u  ', ' _=_=_ ')
    $styleMouth = @('  \_/  ', '  ---  ', '  /~\  ', '   o   ', '  ___  ', '  \_/  ')

    # Lazy, session-persistent assignment: first time we see a name it takes
    # the next hole/face in order; every later spawn of it reuses that.
    if ($null -eq $script:MoleReg) { $script:MoleReg = @{}; $script:MoleNext = 0 }
    if (-not $script:MoleReg.ContainsKey($Name)) {
        $script:MoleReg[$Name] = $script:MoleNext
        $script:MoleNext++
    }
    $ord      = [int]$script:MoleReg[$Name]
    $C        = $slots[$ord % $slots.Count]
    $styleIdx = $ord % $styleEyes.Count

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

        # Reserve artH rows so frame drawing never scrolls the buffer mid-run.
        [Console]::Write([Environment]::NewLine * $artH)
        $anchorTop = [Console]::CursorTop - $artH
        if ($anchorTop -lt 0) { $anchorTop = 0 }

        # ---- tiny flicker-free drawing kit (nested; reads the vars above) ----
        function Center([string]$s, [int]$c) {
            $lp = $c - [int][Math]::Floor($s.Length / 2)
            if ($lp -lt 0) { $lp = 0 }
            return (' ' * $lp) + $s
        }
        function Merge([string]$base, [string]$over) {
            $b = $base.PadRight($artW).Substring(0, $artW).ToCharArray()
            $o = $over.PadRight($artW)
            for ($i = 0; $i -lt $artW; $i++) { if ($o[$i] -ne ' ') { $b[$i] = $o[$i] } }
            return (-join $b)
        }
        function New-Base {
            $c = [string[]]::new($artH)
            for ($i = 0; $i -lt $artH; $i++) { $c[$i] = ' ' * $artW }
            $g12 = ('_' * $artW).ToCharArray()
            $g13 = ('#' * $artW).ToCharArray()
            foreach ($s in $slots) {
                for ($k = -2; $k -le 2; $k++) { $x = $s + $k; if ($x -ge 0 -and $x -lt $artW) { $g12[$x] = ' ' } }
                for ($k = -1; $k -le 1; $k++) { $x = $s + $k; if ($x -ge 0 -and $x -lt $artW) { $g13[$x] = ' ' } }
            }
            $c[12] = -join $g12
            $c[13] = -join $g13
            return ,$c
        }
        function Place($canvas, $lines, [int]$top) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $r = $top + $i
                if ($r -ge 0 -and $r -lt $artH) { $canvas[$r] = Merge $canvas[$r] $lines[$i] }
            }
        }
        # Stamp a left-anchored sprite at (left,top); spaces are transparent.
        function Put($canvas, $sprite, [int]$left, [int]$top) {
            for ($i = 0; $i -lt $sprite.Count; $i++) {
                $r = $top + $i
                if ($r -lt 0 -or $r -ge $artH) { continue }
                $row = $canvas[$r].PadRight($artW).Substring(0, $artW).ToCharArray()
                $s = [string]$sprite[$i]
                for ($j = 0; $j -lt $s.Length; $j++) {
                    $x = $left + $j
                    if ($x -ge 0 -and $x -lt $artW -and $s[$j] -ne ' ') { $row[$x] = $s[$j] }
                }
                $canvas[$r] = -join $row
            }
        }
        # The sideways mallet the whole swing uses - facing left (handle to the
        # right) or right (handle to the left), always the same clean look.
        # $top sets how high it sits, so the same sprite rises and then falls.
        function PutHammer($canvas, [int]$dir, [int]$top) {
            if ($dir -lt 0) {
                Put $canvas @('  .----.', '(o  o |======', "  '----'") ($C - 4) $top
            } else {
                Put $canvas @('      .----.', '======| o  o)', "      '----'") ($C - 8) $top
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

        # ---- this process's mole (centred on ITS hole $C, style $styleIdx) ---
        function MoleLines([bool]$dizzy, [int]$shift) {
            $e = if ($dizzy) { '  x x  ' } else { $styleEyes[$styleIdx] }
            $m = if ($dizzy) { '  vvv  ' } else { $styleMouth[$styleIdx] }
            $rows = @(' .-----. ', ('/' + $e + '\'), ('\' + $m + '/'), ' \_____/ ')
            $out = @()
            foreach ($r in $rows) { $out += (Center $r ($C + $shift)) }
            return ,$out
        }
        # Speech bubble, snugly sized to the text and clamped over the mole.
        function Bubble([string]$text) {
            if ($text.Length -gt 30) { $text = $text.Substring(0, 30) }
            $inner = $text.Length
            $wBox  = $inner + 4
            $left  = $C - [int]($wBox / 2)
            if ($left + $wBox -gt $artW) { $left = $artW - $wBox }
            if ($left -lt 0) { $left = 0 }
            $pad = ' ' * $left
            return @(
                ($pad + '.' + ('-' * ($inner + 2)) + '.'),
                ($pad + '| ' + $text + ' |'),
                ($pad + '`' + ('-' * ($inner + 2)) + '`'),
                (Center '\' $C)
            )
        }

        # Precompute this mole's poses and the splat once.
        $mUp   = MoleLines $false 0
        $mDz   = MoleLines $true  0
        $pkC   = $mUp[0..1]
        $pkL   = (MoleLines $false -1)[0..1]
        $pkR   = (MoleLines $false  1)[0..1]
        $rise  = $mUp[0..2]
        $burst = @((Center '  \ | /  ' $C), (Center '-- >@< --' $C), (Center '  / | \  ' $C))

        # =====================================================================
        #  BEAT 1 - PEEK: the mole pops from ITS hole and glances about.
        # =====================================================================
        $f = New-Base;                    Draw $f $null; Nap 200   # just the holes
        $f = New-Base; Place $f $pkC 10;  Draw $f $null; Nap 260   # eyes up
        $f = New-Base; Place $f $pkL 10;  Draw $f $null; Nap 280   # glance left
        $f = New-Base; Place $f $pkR 10;  Draw $f $null; Nap 280   # glance right
        $f = New-Base; Place $f $rise 9;  Draw $f $null; Nap 130   # rise...
        $f = New-Base; Place $f $mUp  8;  Draw $f $null; Nap 160   # ...fully up

        $fast = Pending

        # =====================================================================
        #  BEAT 2 - ONE LINE: a single random thought, then it's promptly done.
        # =====================================================================
        $quips = @(
            'Oh good. The surface.'
            'I am, at best, a process.'
            'Something knows my PID.'
            'Not this again. Honestly.'
            'Is it all just holes?'
            "I've made a terrible mistake."
            'Fifty seconds. Tops.'
            'Ah, the warm hum of RAM.'
            'Do not watch me. ...Too late.'
            'I exist. Briefly. Loudly.'
            'My whole purpose is this.'
            'Tell my child procs I tried.'
            'Statistically, this ends now.'
            'I peaked at boot.'
            'Here we go. Again. Forever.'
            'I regret every fork.'
        )
        $say = Get-Random -InputObject $quips
        $f = New-Base; Place $f (Bubble $say) 4; Place $f $mUp 8; Draw $f $null
        if ($fast) { Nap 550 } else { Nap 1500 }

        # =====================================================================
        #  BEAT 3 - WIND-UP: a sideways hammer (facing left or right, chosen at
        #  random) rises over the mole, then swings down.
        # =====================================================================
        $dir = Get-Random -InputObject @(-1, 1)
        $wu  = if ($fast) { 70 } else { 230 }
        $f = New-Base; Place $f $mUp 8; PutHammer $f $dir 1; Draw $f $null; Nap $wu               # raised, held
        $f = New-Base; Place $f $mUp 8; PutHammer $f $dir 4; Draw $f $null; Nap ([int]($wu / 2))  # dropping

        # =====================================================================
        #  BEAT 4 - WHACK: the hammer slams onto the mole. In red.
        # =====================================================================
        $script:BonkScore++
        $f = New-Base; Place $f $mDz[1..3] 9; PutHammer $f $dir 6
        Put $f @('*  \ ! /  *') ($C - 5) 5
        Draw $f ([ConsoleColor]::Red); if ($fast) { Nap 170 } else { Nap 450 }
        $f = New-Base; Place $f $burst 8
        Draw $f ([ConsoleColor]::Red); if ($fast) { Nap 160 } else { Nap 400 }

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
        $f = New-Base; Place $f $burst 8; Place $f $score 0
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