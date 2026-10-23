# Remove MT marks (the editor's memoQ menu) must take out every machine-translation
# mark and nothing else, and must hand memoQ back a file it can read.
#
# memoQ records each MT hit inserted into a row as <mq:insertedmatch matchtype="1"
# source="MT / <engine>">, and the record survives editing and confirming. A clean
# copy that also lost a TM match, a status or a byte of text, or a zip that memoQ's
# own reader refuses, would be worse than the mark. The zip case is not
# hypothetical: a rewritten entry that kept memoQ's old header was refused with
# "Size mismatch between central header and local header" on 2026-10-23.
#
# Every case is built in a temp folder. The one real memoQ export,
# fixtures\memoq-export-with-mt.mqxlz, holds test sentences only.
$ErrorActionPreference = 'Stop'
$EditorExe = 'D:\SynologyDrive\Dev\Sv\Supervertaler-for-memoQ\src\Supervertaler.PromptEditor\bin\Release\Supervertaler.PromptEditor.exe'
$Fixture = Join-Path $PSScriptRoot 'fixtures\memoq-export-with-mt.mqxlz'
# memoQ's own zip reader: the check that matters is whether memoQ can read the copy.
$SharpZip = 'C:\Program Files\memoQ\memoQ-12\ICSharpCode.SharpZipLib.dll'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression

$editor = [Reflection.Assembly]::LoadFrom($EditorExe)
$Static = [Reflection.BindingFlags]'Public,NonPublic,Static'
$marksT = $editor.GetType('Supervertaler.PromptEditor.MtMarks')
$resultT = $marksT.GetNestedType('Result', [Reflection.BindingFlags]'Public,NonPublic')
$cleanM = $marksT.GetMethod('Clean', $Static)
$cleanTextM = $marksT.GetMethod('CleanText', $Static)
$labelM = $marksT.GetMethod('EngineLabel', $Static)

$fails = 0
function Check($ok, $label) {
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}

function Field($o, $name) { return $o.GetType().GetField($name).GetValue($o) }

# The exception the method threw, from under PowerShell's and reflection's wrappers.
function Unwrap($e) {
    while ($e.InnerException -and ($e -is [Management.Automation.MethodInvocationException] -or
            $e -is [Reflection.TargetInvocationException])) { $e = $e.InnerException }
    return $e
}

function Clean($path) {
    try { return @{ Result = $cleanM.Invoke($null, [object[]]@([string]$path)); Error = $null } }
    catch { return @{ Result = $null; Error = (Unwrap $_.Exception) } }
}

function CleanText($text) {
    $r = [Activator]::CreateInstance($resultT)
    $out = $cleanTextM.Invoke($null, [object[]]@([string]$text, $r))
    return @{ Text = $out; Result = $r }
}

$dir = Join-Path $env:TEMP 'sv-mtmarks-test'
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$utf8 = New-Object Text.UTF8Encoding($false)
$bom = [byte[]](0xEF, 0xBB, 0xBF)
function Bytes($text, [bool]$withBom) {
    $body = $utf8.GetBytes($text)
    if ($withBom) { return [byte[]]($bom + $body) }
    return $body
}
function Same([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}

# ---- the units: each one before and after, as memoQ writes them ----------------
# CRLF line ends, as memoQ's own exports have.
function Crlf($s) { return ($s -replace "`r?`n", "`r`n") }

# 1. Supervertaler's MT, confirmed; memoQ 12 nests the MT output in the record.
$u1 = Crlf @'
<trans-unit id="1" mq:status="ManuallyConfirmed" mq:segmentguid="g1">
<source xml:space="preserve">Een.</source>
<target xml:space="preserve">One.</target>
<mq:commitinfos><commitinfo role="1000" matchrate="0" /></mq:commitinfos>
<mq:insertedmatch matchtype="1" source="MT / Supervertaler" matchrate="0" originalmatchrate="0"><source xml:space="preserve">Een.</source>
<target xml:space="preserve">One!</target>
</mq:insertedmatch>
</trans-unit>
'@
$u1after = Crlf @'
<trans-unit id="1" mq:status="ManuallyConfirmed" mq:segmentguid="g1">
<source xml:space="preserve">Een.</source>
<target xml:space="preserve">One.</target>
<mq:commitinfos><commitinfo role="1000" matchrate="0" /></mq:commitinfos>
</trans-unit>
'@
# 2. Another engine's MT, not yet confirmed, in the older self-closing form. The
#    status gives MT away by itself, so it becomes Edited.
$u2 = Crlf @'
<trans-unit id="2" mq:status="MachineTranslated" mq:segmentguid="g2">
<source xml:space="preserve">Twee.</source>
<target xml:space="preserve">Two.</target>
<mq:insertedmatch matchtype="1" source="MT / DeepL MT Plugin" matchrate="0" originalmatchrate="0" />
</trans-unit>
'@
$u2after = Crlf @'
<trans-unit id="2" mq:status="PartiallyEdited" mq:segmentguid="g2">
<source xml:space="preserve">Twee.</source>
<target xml:space="preserve">Two.</target>
</trans-unit>
'@
# 3. A TM match: matchtype 0. It stays, record and percentage alike.
$u3 = Crlf @'
<trans-unit id="3" mq:status="ManuallyConfirmed" mq:percent="100" mq:segmentguid="g3">
<source xml:space="preserve">Drie.</source>
<target xml:space="preserve">Three.</target>
<mq:insertedmatch matchtype="0" source="Client TM / " matchrate="100" originalmatchrate="0"><source xml:space="preserve">Drie.</source>
<target xml:space="preserve">Three.</target>
</mq:insertedmatch>
</trans-unit>
'@
# 4. Typed by hand: nothing to take out. Its status names MT-free work and stays.
$u4 = Crlf @'
<trans-unit id="4" mq:status="PartiallyEdited" mq:segmentguid="g4">
<source xml:space="preserve">Vier.</source>
<target xml:space="preserve">Four.</target>
</trans-unit>
'@
# 5. MT now and MT in an earlier version: the history goes too, with its status.
#    An earlier version with no mark is left exactly as it is.
$u5 = Crlf @'
<trans-unit id="5" mq:status="ManuallyConfirmed" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve">Five.</target>
<mq:minorversions>
<mq:historical-unit mq:status="MachineTranslated" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve">Fife.</target>
<mq:insertedmatch matchtype="1" source="MT / Google Cloud Translation Basic plugin" matchrate="0" originalmatchrate="0" />
</mq:historical-unit>
<mq:historical-unit mq:status="NotStarted" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve"></target>
</mq:historical-unit>
</mq:minorversions>
<mq:insertedmatch matchtype="1" source="MT / Supervertaler" matchrate="0" originalmatchrate="0" />
</trans-unit>
'@
$u5after = Crlf @'
<trans-unit id="5" mq:status="ManuallyConfirmed" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve">Five.</target>
<mq:minorversions>
<mq:historical-unit mq:status="PartiallyEdited" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve">Fife.</target>
</mq:historical-unit>
<mq:historical-unit mq:status="NotStarted" mq:segmentguid="g5">
<source xml:space="preserve">Vijf.</source>
<target xml:space="preserve"></target>
</mq:historical-unit>
</mq:minorversions>
</trans-unit>
'@
# 6. memoQ's own AGT names itself without the "MT / " prefix; it is still MT.
#    The text carries an escaped ampersand and must keep it.
$u6 = Crlf @'
<trans-unit id="6" mq:status="ManuallyConfirmed" mq:segmentguid="g6">
<source xml:space="preserve">Zes &amp; zeven.</source>
<target xml:space="preserve">Six &amp; seven.</target>
<mq:insertedmatch matchtype="1" source="MemoQAGT" matchrate="0" originalmatchrate="0" />
</trans-unit>
'@
$u6after = Crlf @'
<trans-unit id="6" mq:status="ManuallyConfirmed" mq:segmentguid="g6">
<source xml:space="preserve">Zes &amp; zeven.</source>
<target xml:space="preserve">Six &amp; seven.</target>
</trans-unit>
'@
# 7. An engine name with an escaped character is counted under its real name.
$u7 = Crlf @'
<trans-unit id="7" mq:status="ManuallyConfirmed" mq:segmentguid="g7">
<source xml:space="preserve">Acht.</source>
<target xml:space="preserve">Eight.</target>
<mq:insertedmatch matchtype="1" source="MT / A&amp;B MT" matchrate="0" originalmatchrate="0" />
</trans-unit>
'@
$u7after = Crlf @'
<trans-unit id="7" mq:status="ManuallyConfirmed" mq:segmentguid="g7">
<source xml:space="preserve">Acht.</source>
<target xml:space="preserve">Eight.</target>
</trans-unit>
'@

$head = Crlf @'
<?xml version="1.0" encoding="UTF-8"?>
<xliff version="1.2" xmlns="urn:oasis:names:tc:xliff:document:1.2" xmlns:mq="MQXliff">
<file original="test.txt" source-language="nl-nl" target-language="en-gb" datatype="x-plaintext">
<body>

'@
$tail = Crlf @'
</body>
</file>
</xliff>
'@
function Doc($units) { return $head + ($units -join '') + $tail }

$before = Doc @($u1, $u2, $u3, $u4, $u5, $u6, $u7)
$after = Doc @($u1after, $u2after, $u3, $u4, $u5after, $u6after, $u7after)

# ---- 1. the text: exactly the marks, and every kind of row ---------------------
$c = CleanText $before
Check ($c.Text -ceq $after) "every MT mark is removed and nothing else changes, byte for byte"
Check ((Field $c.Result 'Removed') -eq 6) "six marks counted, rows and earlier versions alike: $(Field $c.Result 'Removed')"
Check ((Field $c.Result 'StatusesChanged') -eq 2) "Machine translated becomes Edited in a row and in an earlier version: $(Field $c.Result 'StatusesChanged')"
$engines = Field $c.Result 'Engines'
Check ($engines['MT / Supervertaler'] -eq 2 -and $engines['MT / DeepL MT Plugin'] -eq 1 -and
       $engines['MT / Google Cloud Translation Basic plugin'] -eq 1 -and $engines['MemoQAGT'] -eq 1 -and
       $engines['MT / A&B MT'] -eq 1 -and $engines.Count -eq 5) "the marks are counted by engine, escaped names decoded"
Check ($c.Text.Contains('source="Client TM / "') -and $c.Text.Contains('mq:percent="100"')) "a TM match keeps its record and its percentage"
Check ($labelM.Invoke($null, @('MT / DeepL MT Plugin')) -eq 'DeepL MT Plugin' -and
       $labelM.Invoke($null, @('MemoQAGT')) -eq 'MemoQAGT') "the report names engines without memoQ's MT / prefix"

$again = CleanText $c.Text
Check ($again.Text -ceq $c.Text -and (Field $again.Result 'Removed') -eq 0) "a clean document cleaned again is unchanged"

# ---- 2. a plain .mqxliff on disk -------------------------------------------------
$plain = Join-Path $dir 'doc.mqxliff'
[IO.File]::WriteAllBytes($plain, (Bytes $before $true))
$origBytes = [IO.File]::ReadAllBytes($plain)
$r = Clean $plain
Check ($r.Error -eq $null) "a .mqxliff is cleaned without error $(if ($r.Error) { $r.Error.Message })"
$written = Field $r.Result 'WrittenTo'
Check ($written -eq (Join-Path $dir 'Clean\doc.mqxliff')) "the copy goes into a Clean folder beside it, under the same name: $written"
Check (Same ([IO.File]::ReadAllBytes($written)) (Bytes $after $true)) "the copy is the cleaned text with its byte-order mark kept"
Check (Same ([IO.File]::ReadAllBytes($plain)) $origBytes) "the original file is not changed"
Check (-not (Field $r.Result 'Packaged')) "a .mqxliff is reported as unpackaged"

$noBom = Join-Path $dir 'nobom.mqxliff'
[IO.File]::WriteAllBytes($noBom, (Bytes $before $false))
$r = Clean $noBom
Check ((Same ([IO.File]::ReadAllBytes((Field $r.Result 'WrittenTo'))) (Bytes $after $false))) "a file without a byte-order mark does not gain one"

$nothing = Join-Path $dir 'nothing.mqxliff'
[IO.File]::WriteAllBytes($nothing, (Bytes (Doc @($u3, $u4)) $true))
$r = Clean $nothing
Check ((Field $r.Result 'Removed') -eq 0 -and (Field $r.Result 'WrittenTo') -eq $null -and
       -not (Test-Path (Join-Path $dir 'Clean\nothing.mqxliff'))) "a file with no MT marks gets no copy"

# ---- 3. an .mqxlz, read back the way memoQ reads it -----------------------------
$zipPath = Join-Path $dir 'pkg.mqxlz'
$skeleton = [byte[]](1..200 | ForEach-Object { $_ % 256 })
$fs = [IO.File]::Create($zipPath)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
foreach ($entry in @(@('document.mqxliff', (Bytes $before $true)), @('skeleton.xml', $skeleton),
                     @('Versions/0001/document.mqxliff', (Bytes $before $true)))) {
    $e = $zip.CreateEntry($entry[0])
    $s = $e.Open(); $s.Write($entry[1], 0, $entry[1].Length); $s.Dispose()
}
$zip.Dispose(); $fs.Dispose()

$r = Clean $zipPath
Check ($r.Error -eq $null) "an .mqxlz is cleaned without error $(if ($r.Error) { $r.Error.Message })"
Check ((Field $r.Result 'Packaged') -and (Field $r.Result 'Removed') -eq 12) "the document and the earlier version are both cleaned: $(Field $r.Result 'Removed')"

$haveSharpZip = Test-Path $SharpZip
if ($haveSharpZip) { [Reflection.Assembly]::LoadFrom($SharpZip) | Out-Null }

# Reads every entry the way memoQ does; returns name -> bytes, or throws.
function Read-AsMemoQ($path) {
    $zf = New-Object ICSharpCode.SharpZipLib.Zip.ZipFile($path)
    try {
        if (-not $zf.TestArchive($true)) { throw "TestArchive failed" }
        $out = @{}
        for ($i = 0; $i -lt $zf.Count; $i++) {
            $s = $zf.GetInputStream([long]$i)
            $ms = New-Object IO.MemoryStream
            $s.CopyTo($ms); $s.Dispose()
            $out[$zf[$i].Name] = $ms.ToArray()
        }
        return $out
    } finally { $zf.Close() }
}

if ($haveSharpZip) {
    $entries = Read-AsMemoQ (Field $r.Result 'WrittenTo')
    Check ($entries.Count -eq 3) "memoQ's zip reader reads all three entries of the copy"
    Check ((Same $entries['document.mqxliff'] (Bytes $after $true)) -and
           (Same $entries['Versions/0001/document.mqxliff'] (Bytes $after $true))) "both documents in the copy are cleaned exactly"
    Check (Same $entries['skeleton.xml'] $skeleton) "the skeleton is copied byte for byte"
} else {
    Write-Host "SKIP memoQ's zip reader not found at $SharpZip"
}

# memoQ's own export: Zip64 headers, the case that was refused.
if ($haveSharpZip -and (Test-Path $Fixture)) {
    $real = Join-Path $dir 'real.mqxlz'
    Copy-Item $Fixture $real
    $r = Clean $real
    Check ($r.Error -eq $null -and (Field $r.Result 'Removed') -eq 7) "memoQ's own export: six rows and one earlier version cleaned: $(Field $r.Result 'Removed')"
    $entries = Read-AsMemoQ (Field $r.Result 'WrittenTo')
    $doc = $utf8.GetString($entries['document.mqxliff'])
    Check (-not $doc.Contains('insertedmatch') -and -not $doc.Contains('MachineTranslated')) "and memoQ's reader finds no mark left in it"
    Check ((Read-AsMemoQ $real)['skeleton.xml'].Length -eq $entries['skeleton.xml'].Length) "its skeleton comes through whole"
} elseif (-not (Test-Path $Fixture)) {
    $fails++; Write-Host "FAIL the fixture is missing: $Fixture"
}

# ---- 4. failure paths: refused, and nothing written -----------------------------
function Refused($name, $bytes, $expect) {
    $p = Join-Path $dir $name
    [IO.File]::WriteAllBytes($p, [byte[]]$bytes)
    $r = Clean $p
    $copy = [IO.Path]::Combine($dir, 'Clean', $name)
    Check ($r.Error -is [IO.InvalidDataException] -and $r.Error.Message -like $expect -and -not (Test-Path $copy)) `
        "$name is refused ($(if ($r.Error) { $r.Error.Message } else { 'no error' })) and no copy is written"
}

$plainXliff = $before.Replace(' xmlns:mq="MQXliff"', '')
Refused 'other.mqxliff' (Bytes $plainXliff $true) '*not a memoQ XLIFF*'
Refused 'binary.mqxliff' ([byte[]](0xEF, 0xBB, 0xBF, 0xC3, 0x28, 0x41)) '*not valid UTF-8*'
Refused 'damaged.mqxlz' ([byte[]](0x50, 0x4B, 3, 4) + [byte[]](1..60)) '*damaged*'

$emptyZip = Join-Path $dir 'empty.mqxlz'
$fs = [IO.File]::Create($emptyZip)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
$e = $zip.CreateEntry('skeleton.xml'); $s = $e.Open(); $s.Write($skeleton, 0, 10); $s.Dispose()
$zip.Dispose(); $fs.Dispose()
Refused 'empty.mqxlz' ([IO.File]::ReadAllBytes($emptyZip)) '*holds no memoQ XLIFF*'

$r = Clean (Join-Path $dir 'missing.mqxliff')
Check ($r.Error -ne $null -and $r.Error.Message.Length -gt 0) "a missing file is an error with a message, for the report: $(if ($r.Error) { $r.Error.GetType().Name })"

# The copy's name is taken by a read-only file: the run fails, says why, and leaves
# that file, the original and the folder as they were.
$blocked = Join-Path $dir 'blocked.mqxliff'
[IO.File]::WriteAllBytes($blocked, (Bytes $before $true))
$blockedCopy = Join-Path $dir 'Clean\blocked.mqxliff'
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'Clean') | Out-Null
[IO.File]::WriteAllText($blockedCopy, 'keep me')
(Get-Item $blockedCopy).IsReadOnly = $true
$r = Clean $blocked
Check ($r.Error -is [IO.IOException]) "a copy that cannot be written is an error: $(if ($r.Error) { $r.Error.Message } else { 'none' })"
Check ([IO.File]::ReadAllText($blockedCopy) -eq 'keep me') "the file in the way is not changed"
Check (@(Get-ChildItem $dir -Recurse -Filter '*.tmp').Count -eq 0) "no temporary file is left behind"
(Get-Item $blockedCopy).IsReadOnly = $false

# ---- 5. the report: where the copies are, and the step that makes it work -------
$mainT = $editor.GetType('Supervertaler.PromptEditor.MainForm')
$reportM = $mainT.GetMethod('MtMarksReport', $Static)
$tupT = [Type]::GetType('System.ValueTuple`3, mscorlib').MakeGenericType(@([string], $resultT, [string]))

function MakeResult($removed, $writtenTo, $packaged) {
    $r = [Activator]::CreateInstance($resultT)
    $resultT.GetField('Removed').SetValue($r, [int]$removed)
    $resultT.GetField('WrittenTo').SetValue($r, $writtenTo)
    $resultT.GetField('Packaged').SetValue($r, [bool]$packaged)
    if ($removed -gt 0) { (Field $r 'Engines').Add('MT / Supervertaler', [int]$removed) }
    return $r
}

# Each item: path, result (or $null), error (or $null).
function Report($items) {
    $list = [Activator]::CreateInstance([Collections.Generic.List`1].MakeGenericType(@($tupT)))
    foreach ($i in $items) { $list.Add([Activator]::CreateInstance($tupT, [object[]]@($i[0], $i[1], $i[2]))) }
    return $reportM.Invoke($null, [object[]]@(,$list))
}

$jobs = 'D:\Jobs\PROJ-001\exports'
$one = Report @(, @("$jobs\a.mqxlz", (MakeResult 7 "$jobs\Clean\a.mqxlz" $true), $null))
Check ($one -like '*a.mqxlz: 7 MT marks removed (Supervertaler: 7).*') "one file: what was removed, by engine"
Check ($one -like "*The clean copy is in $jobs\Clean.*") "the Clean folder is given as a full path"
Check ($one -like '*select the document and remove it*' -and $one -like '*Import as new*' -and $one -notlike '*Ctrl+A*') "the steps are worded for one document"
Check ($one -like '*memoQ keeps the old marks*') "it warns that an update does not work"

$several = Report @(
    @("$jobs\a.mqxlz", (MakeResult 7 "$jobs\Clean\a.mqxlz" $true), $null),
    @("$jobs\b.mqxlz", (MakeResult 3 "$jobs\Clean\b.mqxlz" $true), $null),
    @("$jobs\c.mqxlz", (MakeResult 0 $null $true), $null),
    @("$jobs\d.mqxlz", $null, 'd.mqxlz is not a memoQ XLIFF file.'))
Check ($several -like '*c.mqxlz: no MT marks in it, so nothing was written.*') "a file without marks is listed as such"
Check ($several -like '*d.mqxlz: not cleaned. d.mqxlz is not a memoQ XLIFF file.*') "a failure is listed with its reason"
Check (([regex]::Matches($several, [regex]::Escape("$jobs\Clean"))).Count -eq 1) "one folder is named once, however many files"
Check ($several -like '*documents and remove them*' -and $several -like '*(Ctrl+A)*') "the steps are worded for several documents"

$none = Report @(, @("$jobs\c.mqxlz", (MakeResult 0 $null $true), $null))
Check ($none -notlike '*Import as new*') "with nothing written there are no steps to follow"

$plainOnly = Report @(, @("$jobs\e.mqxliff", (MakeResult 2 "$jobs\Clean\e.mqxliff" $false), $null))
Check ($plainOnly -like '*for delivering as it is*' -and $plainOnly -notlike '*Import as new*') "a plain .mqxliff gets the delivery note, not the import steps"

# ---- 6. scale: a long document ----------------------------------------------------
# The largest real export seen had 5,141 rows in 10 MB. Twenty thousand rows, a
# third of them MT, must still take seconds, not minutes.
$many = New-Object Text.StringBuilder
for ($i = 0; $i -lt 20000; $i++) {
    switch ($i % 3) {
        0 { [void]$many.Append($u1.Replace('id="1"', "id=""$i""")) }
        1 { [void]$many.Append($u3.Replace('id="3"', "id=""$i""")) }
        2 { [void]$many.Append($u4.Replace('id="4"', "id=""$i""")) }
    }
}
$big = Join-Path $dir 'big.mqxliff'
[IO.File]::WriteAllBytes($big, (Bytes ($head + $many.ToString() + $tail) $true))
$mb = [math]::Round((Get-Item $big).Length / 1MB, 1)
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Clean $big
$sw.Stop()
Check ($r.Error -eq $null -and (Field $r.Result 'Removed') -eq 6667) "20,000 rows ($mb MB): 6,667 marks removed: $(Field $r.Result 'Removed')"
Check ($sw.Elapsed.TotalSeconds -lt 10) "in $([math]::Round($sw.Elapsed.TotalSeconds, 2)) s"

Remove-Item -Recurse -Force $dir
Write-Host ""
if ($fails -eq 0) { Write-Host "ALL PASSED" } else { Write-Host "$fails FAILED" }
exit $fails
