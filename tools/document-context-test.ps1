# The document's source text goes into the cached half of every request
# (docs/design/whole-document-context.md). That half is only cheap while it is
# identical to the byte from one request to the next: one changed character and
# every request pays the write rate for the prompt, the bank and the document.
# Nothing fails when that breaks - the bill is just several times what it should
# be - so this checks the property itself, across a simulated run:
#
#   1. the block: core's heading and wording, tags out, numbering
#   2. the limit, cut 80/20, and the long-document box
#   3. captured rows cut at a fixed point, so the block moves only at doublings
#   4. a run, batch by batch: the system prompt stays identical between
#      doublings, memoQ's second engine builds the same bytes, and with the
#      live link it never changes at all
#   5. what is not sent: the box off, a local provider, an unnamed document
#
# Writes nothing to the user's settings: the three settings the block depends on
# are passed in, because memoQ may be running and reading that file. Run it
# through tools/run-harness.ps1 all the same.
param(
    [string]$MemoQPath = 'C:\Program Files\memoQ\memoQ-12',
    [string]$PluginDll = "$PSScriptRoot\..\src\Supervertaler.MemoQ\bin\Release\Supervertaler.MemoQ.dll"
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$script:probed = @{}
[AppDomain]::CurrentDomain.add_AssemblyResolve([System.ResolveEventHandler] {
    param($s, $e)
    $name = ($e.Name -split ',')[0]
    if ($script:probed.ContainsKey($name)) { return $null }
    $script:probed[$name] = $true
    foreach ($dir in @($MemoQPath, "$MemoQPath\Addins")) {
        $c = Join-Path $dir "$name.dll"
        if (Test-Path $c) { try { return [Reflection.Assembly]::LoadFrom($c) } catch { return $null } }
    }
    return $null
})

if (-not $env:SUPERVERTALER_HARNESS) { Write-Host 'ABORT: run this through tools/run-harness.ps1.'; exit 1 }

$plugin = [Reflection.Assembly]::LoadFrom((Resolve-Path $PluginDll))
$mt     = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.MTInterfaces.dll")
$common = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
$Static   = [Reflection.BindingFlags]'Public,NonPublic,Static'
$Instance = [Reflection.BindingFlags]'Public,NonPublic,Instance'

$fails = 0
function Check($ok, $label) {
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}

# Members of internal types, which PowerShell does not adapt.
function F($obj, $name) { return $obj.GetType().GetField($name).GetValue($obj) }
function P($obj, $name) { return $obj.GetType().GetProperty($name).GetValue($obj) }

# The object itself, not PowerShell's wrapper around it: inside an argument
# array a wrapped list reaches .NET as a PSObject and the call fails.
function U($obj) { if ($null -eq $obj) { return $null }; return , $obj.PSObject.BaseObject }

$dc      = $plugin.GetType('Supervertaler.MemoQ.Core.DocumentContext')
$build   = $dc.GetMethod('Build', $Static)
$measure = $dc.GetMethod('Measure', $Static)
$step    = $dc.GetMethod('Step', $Static)
$prefixM = $dc.GetMethod('CapturedPrefix', $Static)
$normal  = [int]$dc.GetField('NormalChars', $Static).GetValue($null)
$whole   = [int]$dc.GetField('WholeChars', $Static).GetValue($null)

function Rows([int]$count, [int]$from = 1, [string]$word = 'Paragraph') {
    $list = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $from; $i -lt $from + $count; $i++) {
        $list.Add(('{0} {1:D5} describes how the widget assembly is mounted on the frame of the device.' -f $word, $i))
    }
    return , $list
}
function Block($rows, [bool]$live, [int]$max) { return $build.Invoke($null, @((U $rows), $live, $max)) }
# @(,$list): a list given alone would otherwise be unrolled into one argument per row.
function StepOf($rows) { return [int]$step.Invoke($null, @([long]$measure.Invoke($null, @(, (U $rows))))) }

# ---- 1. the block itself --------------------------------------------------------
$rows = Rows 20
$rows.Insert(5, '   ')                                              # a blank row: skipped, numbering stays whole
$rows.Add('A <b>bold</b> claim with <bpt id="1"/>a tag<ept id="1"/> &amp; an escape.')
$r = Block $rows $true $normal
$t = [string](F $r 'Text')
Check ($t.StartsWith('# DOCUMENT CONTENT')) 'the block opens with Trados''s heading, so library prompts that name it find it'
Check ($t.Contains('Analyze it to determine the document type')) 'with core''s own wording'
Check ($t.Contains('Each numbered line is one paragraph') -and $t.Contains("not memoQ's row numbers")) 'and says the numbers are not memoQ''s rows'
Check ($t.Contains("`n1. Paragraph 00001") -and $t.Contains("`n20. Paragraph 00020")) 'rows numbered from 1'
Check ($t.Contains('21. A bold claim with a tag & an escape.')) 'tags removed and escapes undone, the blank row skipped'
Check ((F $r 'Sent') -eq 21 -and (F $r 'Omitted') -eq 0) 'all 21 rows sent, none left out'
Check ($null -eq (Block (New-Object 'System.Collections.Generic.List[string]') $true $normal)) 'no rows, no block'

# ---- 2. the limit, cut 80/20 ---------------------------------------------------
$big = Rows 3000                                                   # about 300,000 characters
$r = Block $big $true $normal
$t = [string](F $r 'Text')
Check ($t.Length -le $normal + 1000) "within the normal limit: $($t.Length) characters for $normal"
Check ($t.Contains("`n1. Paragraph 00001") -and $t.Contains("`n3000. Paragraph 03000")) 'keeps the start and the end of the document'
$omitted = [int](F $r 'Omitted'); $sent = [int](F $r 'Sent')
Check ($omitted -gt 0 -and $t.Contains("[... $omitted paragraphs omitted ...]")) "says how much was left out between: $omitted paragraphs"
$headRows = ([regex]::Matches($t.Substring(0, $t.IndexOf('[...')), "(?m)^\d+\. ")).Count
Check ([math]::Abs($headRows / $sent - 0.8) -lt 0.02) "80% from the start: $headRows of $sent rows"
$w = Block $big $true $whole
Check ((F $w 'Omitted') -eq 0 -and ([string](F $w 'Text')).Contains("`n3000. Paragraph 03000") -and (F $w 'Sent') -eq 3000) 'the long-document box sends all 3,000'
$huge = Rows 9000                                                  # about 900,000 characters
$h = Block $huge $true $whole
Check ((F $h 'Omitted') -gt 0 -and ([string](F $h 'Text')).Length -le $whole + 1000) 'and cuts past its own limit too'

# ---- 3. captured rows: cut at a fixed point ------------------------------------
$all = Rows 400 1 'Segment'
$moves = 0; $stable = $true; $lastText = $null; $lastStep = $null; $halfOrMore = $true
for ($n = 1; $n -le $all.Count; $n++) {
    $seen = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $n; $i++) { $seen.Add($all[$i]) }
    $res = Block $seen $false $normal
    $text = if ($res) { [string](F $res 'Text') } else { $null }
    $s = StepOf $seen
    if ($null -ne $lastStep -and $s -eq $lastStep -and $text -ne $lastText) { $stable = $false }
    if ($text -ne $lastText) { $moves++ }
    if ($res) {
        $cut = $prefixM.Invoke($null, @(, (U $seen)))
        if ([long]$measure.Invoke($null, @(, (U $cut))) * 2 -lt [long]$measure.Invoke($null, @(, (U $seen)))) { $halfOrMore = $false }
    }
    $lastText = $text; $lastStep = $s
}
Check $stable 'captured rows: the block does not change between doublings, whatever arrives'
Check ($moves -le 8) "and changes $moves times over 400 rows, not once a batch"
Check $halfOrMore 'and always holds at least half of what was captured'
Check ($lastText.Contains('in the order memoQ sent them')) 'and says it may stop before the end'

# ---- 4. a run, batch by batch ----------------------------------------------------
$generalT  = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
$secureT   = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings')
$settingsT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings')
$engineT   = $plugin.GetType('Supervertaler.MemoQ.Core.EngineContext')
$store     = $plugin.GetType('Supervertaler.MemoQ.Core.CaptureStore')
$preview   = $plugin.GetType('Supervertaler.MemoQ.Core.PreviewStore')
$partT     = $plugin.GetType('Supervertaler.MemoQ.Core.PreviewStore+Part')
$builder   = $plugin.GetType('Supervertaler.MemoQ.Core.PromptBuilder')
$metaT     = $mt.GetType('MemoQ.MTInterfaces.MTRequestMetadata')
$off       = [Activator]::CreateInstance($plugin.GetType('Supervertaler.Core.StructureContextMode'))
$general   = [Activator]::CreateInstance($generalT)
$settings  = $settingsT.GetMethod('Create').Invoke($null, @($general, [Activator]::CreateInstance($secureT)))

function Engine([Guid]$document) {
    $ctx = [Activator]::CreateInstance($engineT, $Instance, $null, @($settings, 'eng', 'nld'), $null)
    if ($document -ne [Guid]::Empty) {
        $m = [Activator]::CreateInstance($metaT)
        $metaT.GetProperty('DocumentID').SetValue($m, $document)
        [void]$engineT.GetMethod('NoteMetadata').Invoke($ctx, @((U $m)))
    }
    return $ctx
}
$docBlock = $engineT.GetMethod('DocumentContextBlock', $Instance, $null, [Type[]]@([bool], [string], [bool]), $null)
function DocOf($ctx, [bool]$send = $true, [string]$provider = 'Anthropic', [bool]$long = $false) {
    return $docBlock.Invoke((U $ctx), @($send, $provider, $long))
}
$recordM = $store.GetMethod('Record', [Type[]]@($engineT, [string]))
function Record($ctx, [string]$text) { [void]$recordM.Invoke($null, @((U $ctx), $text)) }
function Batch($document) {
    $built = $builder.GetMethod('BuildForBatch', $Static).Invoke($null,
        @((U $general), 'eng', 'nld', $null, $null, $null, 'INSTRUCTIONS-MARKER', 'BANK-MARKER', (U $off), $document))
    return $built
}

# Without the live link: memoQ's two engines for the pair, the second asking
# only every third batch - so it builds its block at other moments than the
# first, which is exactly when "whatever had arrived" would differ.
$doc = [Guid]::NewGuid()
$a = Engine $doc; $b = Engine $doc
$systems = New-Object 'System.Collections.Generic.List[string]'
$agree = $true
$run = Rows 400 1 'Captured'
for ($k = 0; $k -lt 40; $k++) {
    for ($i = 0; $i -lt 10; $i++) { Record $a $run[$k * 10 + $i] }
    $sysA = [string](P (Batch (DocOf $a)) 'System')
    if ($k % 3 -eq 2) {
        $sysB = [string](P (Batch (DocOf $b)) 'System')
        if ($sysA -ne $sysB) { $agree = $false }
    }
    $systems.Add($sysA)
}
$changes = 0
for ($k = 1; $k -lt $systems.Count; $k++) { if ($systems[$k] -ne $systems[$k - 1]) { $changes++ } }
Check ($changes -ge 1 -and $changes -le 7) "40 batches without the live link: the system prompt changed $changes times, at doublings only"
Check $agree "memoQ's second engine built the same bytes at every batch it asked"
$last = $systems[$systems.Count - 1]
$iBank = $last.IndexOf('BANK-MARKER'); $iDoc = $last.IndexOf('# DOCUMENT CONTENT'); $iContract = $last.IndexOf('# OUTPUT CONTRACT')
Check ($iBank -ge 0 -and $iBank -lt $iDoc -and $iDoc -lt $iContract) 'the document sits after the bank and before the output contract'
$user = [string](P (Batch (DocOf $a)) 'User')
Check (-not $user.Contains('Captured 00001')) 'and not in the half that changes every request'

# The single-segment path gets the same system half, so a lookup and a batch
# share one cache entry.
$segB    = $common.GetType('MemoQ.Addins.Common.DataStructures.SegmentBuilder')
$bundleT = $mt.GetType('MemoQ.MTInterfaces.TranslationBundle')
$bundle  = [Activator]::CreateInstance($bundleT)
$bundleT.GetField('Source').SetValue($bundle, $segB.GetMethod('CreateFromString').Invoke($null, @('A device comprising a widget.')))
$one = $builder.GetMethod('Build', $Static).Invoke($null,
    @((U $bundle), (U $general), 'eng', 'nld', $null, $null, $null, 'INSTRUCTIONS-MARKER', 'BANK-MARKER', (U $off), $null, (DocOf $a)))
Check ([string](P $one 'System') -eq $last) 'a lookup on a row sends the same system half as Pre-translate'

# With the live link: the whole document from the first batch, and never a change.
$doc2 = [Guid]::NewGuid()
$view = [Guid]::NewGuid().ToString()
# A list of the store's own part type, which New-Object cannot name.
function PartList { return , [Activator]::CreateInstance([Collections.Generic.List`1].MakeGenericType(@($partT))) }
$parts = PartList
$paras = Rows 120 1 'Live'
for ($n = 0; $n -lt $paras.Count; $n++) {
    $p = [Activator]::CreateInstance($partT)
    $partT.GetField('PartId').SetValue($p, "mQ-default-$view-$($n + 1)")
    $partT.GetField('DocumentGuid').SetValue($p, $doc2)
    $partT.GetField('Source').SetValue($p, $paras[$n])
    $parts.Add($p)
}
[void]$preview.GetMethod('Upsert', $Static).Invoke($null, @(, (U $parts)))
$c = Engine $doc2; $d = Engine $doc2
$liveSystems = New-Object 'System.Collections.Generic.List[string]'
for ($k = 0; $k -lt 12; $k++) {
    for ($i = 0; $i -lt 10; $i++) { Record $c "Captured row $k-$i of the live document." }
    if ($k -eq 6) {
        # The translator confirms a row: memoQ sends the part again with its new target.
        $edited = [Activator]::CreateInstance($partT)
        $partT.GetField('PartId').SetValue($edited, "mQ-default-$view-5")
        $partT.GetField('DocumentGuid').SetValue($edited, $doc2)
        $partT.GetField('Source').SetValue($edited, $paras[4])
        $partT.GetField('Target').SetValue($edited, 'Een vertaling.')
        $one5 = PartList; $one5.Add($edited)
        [void]$preview.GetMethod('Upsert', $Static).Invoke($null, @(, (U $one5)))
    }
    $liveSystems.Add([string](P (Batch (DocOf $c)) 'System'))
}
$distinct = @($liveSystems | Select-Object -Unique).Count
Check ($distinct -eq 1) "12 batches with the live link: $distinct system prompt, through a confirmed row as well"
Check ($liveSystems[0].Contains("`n120. Live 00120") -and $liveSystems[0].Contains('one paragraph of the document')) 'the whole document from the first batch'
Check ([string](P (Batch (DocOf $d)) 'System') -eq $liveSystems[0]) "and memoQ's second engine sends the same"
Check (-not $liveSystems[0].Contains('Captured row')) 'the live link wins over the captured rows'

# ---- 5. what is not sent --------------------------------------------------------
Check ($null -eq (DocOf $c $false)) 'the document box off: no document'
Check ($null -eq (DocOf $c $true 'Ollama')) 'Ollama: no document'
Check ($null -eq (DocOf $c $true 'OpenAI-compatible')) 'an OpenAI-compatible server: no document'
$again = [string](DocOf $c)
Check ($again.Length -gt 0 -and $liveSystems[0].Contains($again)) 'back on a cloud provider, the same block again'
$nameless = Engine ([Guid]::Empty)
for ($i = 0; $i -lt 50; $i++) { Record $nameless "Row $i of a document memoQ did not name, long enough to count." }
Check ($null -eq (DocOf $nameless)) 'a document memoQ has not named: no document, its rows may be several documents'

$doc3 = [Guid]::NewGuid()
$bigParts = PartList
$bigRows = Rows 3000 1 'Long'
for ($n = 0; $n -lt $bigRows.Count; $n++) {
    $p = [Activator]::CreateInstance($partT)
    $partT.GetField('PartId').SetValue($p, "mQ-default-$view-x-$($n + 1)")
    $partT.GetField('DocumentGuid').SetValue($p, $doc3)
    $partT.GetField('Source').SetValue($p, $bigRows[$n])
    $bigParts.Add($p)
}
[void]$preview.GetMethod('Upsert', $Static).Invoke($null, @(, (U $bigParts)))
$e = Engine $doc3
$normalBlock = [string](DocOf $e)
$wholeBlock  = [string](DocOf $e $true 'Anthropic' $true)
Check ($normalBlock.Contains('paragraphs omitted') -and -not $wholeBlock.Contains('omitted')) "a 3,000-paragraph document: about $([int]($normalBlock.Length / 4)) tokens normally, all of it ($([int]($wholeBlock.Length / 4)) tokens) with the long-document box"

Write-Host
if ($fails -eq 0) { Write-Host 'All document-context checks passed.' } else { Write-Host "$fails check(s) FAILED." }
exit $fails
