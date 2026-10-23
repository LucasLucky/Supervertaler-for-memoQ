# The shared memory bank: made at start-up, and makeable by name.
#
# Nothing in either product made _shared, so a new user had to know it was a
# folder to create in File Explorer, and the rule that keeps bank names safe
# in a path strips a leading underscore: typing _shared into New memory bank
# made an ordinary bank called "shared", which is never sent as the shared
# one. Now memoQ and the editor make it at start-up when it is missing. This
# pins that: it is made on a fresh data folder, an untouched one sends the
# model nothing, a bank that exists is left exactly as it is, a harness never
# makes one, a failure is reported rather than thrown, and New memory bank
# keeps the name.
#
# Everything happens under temp data folders, set in-process. The
# translator's own banks are never read or written.
$ErrorActionPreference = 'Stop'
$EditorExe = 'D:\SynologyDrive\Dev\Sv\Supervertaler-for-memoQ\src\Supervertaler.PromptEditor\bin\Release\Supervertaler.PromptEditor.exe'

$editor = [Reflection.Assembly]::LoadFrom($EditorExe)
$Static = [Reflection.BindingFlags]'Public,NonPublic,Static'

$folderT = $editor.GetType('Supervertaler.MemoQ.Core.BankFolder')
$paths = $editor.GetType('Supervertaler.Core.SupervertalerPaths')
$readerT = $editor.GetType('Supervertaler.Core.MemoryBankReader')
$shared = $editor.GetType('Supervertaler.MemoQ.Core.SharedSettings')

$fails = 0
function Check($ok, $label) {
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}

function Method($name, $count) {
    $m = @($folderT.GetMethods($Static) | Where-Object { $_.Name -eq $name -and $_.GetParameters().Count -eq $count })
    if ($m.Count -ne 1) { throw "$($m.Count) methods named $name take $count arguments" }
    return $m[0]
}

# Create(root, name, out error): the out parameter comes back in the array.
function Make($root, $name) {
    $argv = New-Object object[] 3
    $argv[0] = [string]$root; $argv[1] = [string]$name; $argv[2] = $null
    $made = (Method 'Create' 3).Invoke($null, $argv)
    return @{ Name = $made; Error = $argv[2] }
}

# EnsureShared(banks folder, data folder, log), collecting what it logs. The
# data folder defaults to the banks folder's parent, as it is in real use.
$script:logged = @()
$log = [Action[string]] { param($line) $script:logged += $line }
function Ensure($root, $dataRoot = (Split-Path $root -Parent)) {
    $script:logged = @()
    $argv = New-Object object[] 3
    $argv[0] = [string]$root; $argv[1] = [string]$dataRoot; $argv[2] = $log
    (Method 'EnsureShared' 3).Invoke($null, $argv) | Out-Null
}

# A client bank's context, as the plugin reads it for translation.
function Context($bankDir) {
    $reader = [Activator]::CreateInstance($readerT, @([string]$bankDir))
    return $reader.LoadContext('PROJ-001', $null, 'en', 'nl', 32000, $null, $true)
}

function Text($path) { return [IO.File]::ReadAllText($path) }

$base = Join-Path $env:TEMP ('sv-shared-bank-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $base | Out-Null

try {
    # ---- 1. made at start-up, on a data folder that has never had a bank -----
    $banks = Join-Path $base 'memory-banks'
    Ensure $banks
    $sh = Join-Path $banks '_shared'
    Check ((Test-Path "$sh\brief.md") -and (Test-Path "$sh\terminology.md") -and (Test-Path "$sh\style.md")) `
        'a fresh data folder gets _shared, with a brief, a terminology table and a style guide'
    Check (-not (Test-Path (Join-Path $banks 'shared'))) 'named with its underscore'
    Check ($script:logged.Count -eq 1 -and $script:logged[0] -like 'Made the shared memory bank at *') `
        "and says so in the log: $($script:logged -join ' | ')"
    Check ((Text "$sh\brief.md") -match '^# _shared') 'the files are core''s skeletons, named for the folder'

    $bytes = [IO.File]::ReadAllBytes("$sh\brief.md")
    Check (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
        'written without a byte order mark, which would reach the prompt as three characters'

    # ---- 2. an untouched shared bank sends nothing --------------------------
    # The reader leaves out a file that is still exactly core's skeleton, so
    # making the bank for everyone costs nobody a token. A first version gave
    # _shared wording of its own, which the reader did not recognise: every
    # request would have carried empty headings, presented to the model as the
    # translator's decisions.
    $r = Make $banks 'Acme Legal'
    $acme = Join-Path $banks 'Acme Legal'
    $ctx = Context $acme
    Check ($null -eq $ctx -or ($null -eq $ctx.SharedBriefText -and $null -eq $ctx.SharedTerminologyText -and $null -eq $ctx.SharedStyleText)) `
        'a shared bank nobody has written in sends nothing'

    # ---- 3. a bank that exists is the translator's ---------------------------
    $mine = "# House defaults`r`n`r`nMy own rules.`r`n"
    [IO.File]::WriteAllText("$sh\brief.md", $mine, (New-Object Text.UTF8Encoding($false)))
    Remove-Item "$sh\style.md"

    Ensure $banks
    Check ((Text "$sh\brief.md") -eq $mine) 'starting again leaves a written brief alone'
    Check (-not (Test-Path "$sh\style.md")) 'and a file the translator deleted stays deleted'
    Check ($script:logged.Count -eq 0) 'and logs nothing, because it did nothing'

    $ctx = Context $acme
    Check ($null -ne $ctx -and $ctx.SharedBriefText -eq $mine.Trim()) `
        'once written in, the shared brief is loaded under the client bank beside it'

    # ---- 4. a failure is reported, never thrown ------------------------------
    $notAFolder = Join-Path $base 'not-a-folder'
    [IO.File]::WriteAllText($notAFolder, 'a file where the banks folder should be')
    $threw = $false
    try { Ensure $notAFolder } catch { $threw = $true }
    Check (-not $threw) 'a banks folder that cannot be written does not stop a start'
    Check ($script:logged.Count -eq 1 -and $script:logged[0] -like 'Could not make the shared memory bank*') `
        "and the log says why: $(($script:logged -join ' ') -replace '\s+', ' ')"

    # ---- 4b. an old single bank Trados has yet to move ----------------------
    # Trados offers to move memory-bank\ (or supermemory\) into memory-banks\
    # only while memory-banks\ does not exist, so making _shared first would
    # end the offer for good and leave the old bank sending nothing.
    $old = Join-Path $base 'legacy'
    New-Item -ItemType Directory -Force -Path (Join-Path $old 'supermemory') | Out-Null
    Ensure (Join-Path $old 'memory-banks')
    Check (-not (Test-Path (Join-Path $old 'memory-banks'))) 'with an old single bank waiting for Trados, nothing is made'
    Check ($script:logged.Count -eq 1 -and $script:logged[0] -like 'Not making the shared memory bank yet:*supermemory*') `
        "and the log says why: $($script:logged -join ' | ')"

    # Once Trados has moved it, memory-banks\ exists and the offer is over.
    New-Item -ItemType Directory -Force -Path (Join-Path $old 'memory-banks\old-bank') | Out-Null
    Ensure (Join-Path $old 'memory-banks')
    Check (Test-Path (Join-Path $old 'memory-banks\_shared\brief.md')) 'once the banks folder exists, the next start makes it'

    # ---- 5. never under a harness --------------------------------------------
    # The start-up call, pointed at a temp data folder that has no _shared.
    $base2 = Join-Path $base 'second'
    New-Item -ItemType Directory -Force -Path (Join-Path $base2 'memory-banks') | Out-Null
    $paths.GetMethod('Set', $Static).Invoke($null, @([string]$base2)) | Out-Null
    try {
        Check ($shared.GetProperty('InHarness', $Static).GetValue($null)) 'this run is a harness (run it through run-harness.ps1)'
        $argv = New-Object object[] 1
        $argv[0] = $log
        (Method 'EnsureShared' 1).Invoke($null, $argv) | Out-Null
        Check (-not (Test-Path (Join-Path $base2 'memory-banks\_shared'))) 'and under a harness the start-up call makes nothing'
    }
    finally {
        $paths.GetMethod('Reset', $Static).Invoke($null, @()) | Out-Null
    }

    # ---- 6. New memory bank keeps the name -----------------------------------
    $banks3 = Join-Path $base 'third'
    New-Item -ItemType Directory -Force -Path $banks3 | Out-Null

    $r = Make $banks3 '_shared'
    Check ($r.Name -eq '_shared') "typing _shared makes _shared: got '$($r.Name)'"
    Check (-not (Test-Path (Join-Path $banks3 'shared'))) 'and no ordinary bank called "shared" appears beside it'

    $r = Make $banks3 '  _Shared '
    Check ($r.Name -eq '_shared') "in any case and with spaces, it is the same bank: '$($r.Name)'"

    $r = Make $banks3 '_beta'
    Check ($r.Name -eq 'beta') "any other leading underscore is still stripped: '$($r.Name)'"

    # ---- 7. client banks are as they were ------------------------------------
    $r = Make $banks3 'Acme Legal'
    Check ($r.Name -eq 'Acme Legal') "a client bank keeps its name: '$($r.Name)'"
    Check (Test-Path (Join-Path $banks3 'Acme Legal\reference')) 'and gets its reference folder'
    Check ((Text (Join-Path $banks3 'Acme Legal\brief.md')) -match 'Who this client is') 'and the client template from core'

    New-Item -ItemType Directory -Path (Join-Path $banks3 'ACME-PATENTS') | Out-Null
    $r = Make $banks3 'acme-patents'
    Check ($r.Name -eq 'ACME-PATENTS') "an existing bank comes back as it is spelt on disk: '$($r.Name)'"

    # The skeleton carries the folder's own spelling, or the reader would not
    # recognise it as untouched and would send it.
    $ctx = Context (Join-Path $banks3 'ACME-PATENTS')
    Check ($null -eq $ctx -or $null -eq $ctx.ClientProfileText) `
        'and its new brief is recognised as untouched, so it sends nothing either'

    # ---- 8. refusals say why -------------------------------------------------
    $r = Make $banks3 '___'
    Check ($null -eq $r.Name -and $r.Error -match 'nothing in it') 'a name with nothing usable is refused with a reason'

    [IO.File]::WriteAllText((Join-Path $banks3 'blocked'), 'a file, not a folder')
    $r = Make $banks3 'blocked'
    Check ($null -eq $r.Name -and $r.Error -match 'Could not create') 'a folder that cannot be made is refused with a reason'
}
finally {
    Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}

Write-Host
if ($fails -gt 0) { Write-Host "$fails check(s) FAILED"; exit 1 }
Write-Host 'All checks passed.'
