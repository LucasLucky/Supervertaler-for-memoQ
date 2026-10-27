# Bridge mode and memoQ's grid (2026-10-22).
#
# memoQ 12.5 asks for the row the translator lands on through ISession's ARRAY
# overload, exactly as Pre-translate does, so bridge mode captured those rows too
# and the translator got "No staged translation" under the grid instead of a
# suggestion. The plugin now tells the two apart by memoQ's own code on the call
# stack (Core\LookupOrigin.cs), names measured live on 2026-10-22.
#
# This test puts memoQ's real method names on the stack - stand-in classes in
# memoQ's namespaces, compiled below - and calls the real session through them, so
# the stack walk sees what it sees inside memoQ. Under run-harness.ps1 there is no
# API key, so "went to the model" shows as a key error, never as a billable call.
#
#   powershell -NoProfile -File tools\run-harness.ps1 -Harness tools\lookup-origin-test.ps1
#
# What it cannot reach: whether memoQ still uses these names. Only a live check
# in memoQ shows that, and the plugin log says "caller not recognised" on every
# captured batch when it does not.
$ErrorActionPreference = 'Stop'
if (Get-Process memoQ -ErrorAction SilentlyContinue) { throw 'memoQ is running: this harness starts its own bridge and must not compete with the live one. Close memoQ first.' }
if (Get-Process Supervertaler.MemoQ.Preview -ErrorAction SilentlyContinue) { throw 'The Supervertaler preview tool is running (an orphan if memoQ is closed): it would connect to this harness bridge and eat its commands. Stop it from the tray, or: taskkill /IM Supervertaler.MemoQ.Preview.exe /F' }
$MemoQPath = 'C:\Program Files\memoQ\memoQ-12'
# Its own checkout, so a worktree's run tests that worktree's source and build.
$Root = Split-Path $PSScriptRoot -Parent
$Bin = "$Root\src"

# Compiled, not a scriptblock: the bridge answers on thread-pool threads, where a
# scriptblock handler has no runspace (see bridgemode-test.ps1).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

public static class LookupOriginHarnessResolver
{
    static string[] probe;
    [ThreadStatic] static Dictionary<string, bool> inFlight;

    public static void Attach(string[] dirs)
    {
        probe = dirs;
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
    }

    static Assembly Resolve(object sender, ResolveEventArgs e)
    {
        string name = new AssemblyName(e.Name).Name;
        if (inFlight == null) inFlight = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        if (inFlight.ContainsKey(name)) return null;
        inFlight[name] = true;
        try
        {
            foreach (string dir in probe)
            {
                string candidate = Path.Combine(dir, name + ".dll");
                if (File.Exists(candidate)) return Assembly.LoadFrom(candidate);
            }
            return null;
        }
        catch { return null; }
        finally { inFlight.Remove(name); }
    }
}
'@
[LookupOriginHarnessResolver]::Attach([string[]]@($MemoQPath, "$MemoQPath\Addins", "$Bin\Supervertaler.MemoQ\bin\Release"))

# memoQ's two callers, by the names seen on the stack in memoQ 12.5. NoInlining
# keeps each frame on the stack; the session is called through reflection from
# inside it, as memoQ calls it from inside its own.
Add-Type -TypeDefinition @'
using System.Reflection;
using System.Runtime.CompilerServices;

namespace MemoQ.TranslationEnvironment.MT.Managers.Local
{
    public static class ClientMTManager
    {
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static object SyncLookupSingle(MethodInfo method, object session, object[] args)
        {
            return method.Invoke(session, args);
        }
    }
}

namespace MemoQ.Project
{
    public static class PreTranslateAndStatisticsJob
    {
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static object preTranslateBatchMT(MethodInfo method, object session, object[] args)
        {
            return method.Invoke(session, args);
        }
    }
}
'@

$mt     = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.MTInterfaces.dll")
$common = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
$main   = [Reflection.Assembly]::LoadFrom("$Bin\Supervertaler.MemoQ\bin\Release\Supervertaler.MemoQ.dll")

$fails = 0; $total = 0
function Check($ok, $label) {
    $script:total++
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}

# ---- 1. the rule, without memoQ ---------------------------------------------
$detector = $main.GetType('Supervertaler.MemoQ.Core.LookupOriginDetector')
$NonPublicStatic = [Reflection.BindingFlags]'NonPublic,Static'
$fromFrames = $detector.GetMethod('FromFrames', $NonPublicStatic)
function Origin([string[]]$frames) { "$($fromFrames.Invoke($null, @(,$frames)))" }

# As logged by the probe build on 2026-10-22, nearest first.
$click = @(
    'MemoQ.TranslationEnvironment.MT.Common.SessionCountingIMTEngineWrapper.DoLookup',
    'MemoQ.TranslationEnvironment.MT.Common.MTManagerBase+<>c__DisplayClass22_0.<Lookup>b__0',
    'MemoQ.TranslationEnvironment.MT.Common.MTManagerBase.Lookup',
    'MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.Lookup',
    'MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.SyncLookupSingle')
$pretranslate = @(
    'MemoQ.TranslationEnvironment.MT.Common.SessionCountingIMTEngineWrapper.DoLookup',
    'MemoQ.TranslationEnvironment.MT.Common.MTManagerBase.Lookup',
    'MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.Lookup',
    'MemoQ.Project.PreTranslateAndStatisticsController.doMTLookup',
    'MemoQ.Project.PreTranslateAndStatisticsJob`1.preTranslateBatchMT',
    'MemoQ.Project.PreTranslateAndStatisticsJob`1.pretranslateBatch',
    'MemoQ.Common.Job.JobBase.Execute')

Check ((Origin $click) -eq 'Grid') "a click into a row (memoQ 12.5's real stack) is a grid lookup"
Check ((Origin $pretranslate) -eq 'PreTranslate') "a Pre-translate (memoQ 12.5's real stack) is a Pre-translate"
Check ((Origin ($click + $pretranslate)) -eq 'PreTranslate') "both on the stack: Pre-translate wins (grid frame nearer)"
Check ((Origin ($pretranslate + $click)) -eq 'PreTranslate') "both on the stack: Pre-translate wins (Pre-translate frame nearer)"
Check ((Origin @('MemoQ.TranslationEnvironment.MT.Common.MTManagerBase.Lookup', 'MemoQ.Grid.RowLookupRenamed.Fetch')) -eq 'Unknown') `
    "memoQ's names renamed: unknown, which bridge mode captures as before"
Check ((Origin @()) -eq 'Unknown') "no frames at all: unknown"
Check ("$($fromFrames.Invoke($null, @($null)))" -eq 'Unknown') "no frame list at all: unknown, no exception"
Check ((Origin @($null, '', 'MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.SyncLookupSingle')) -eq 'Grid') `
    "empty entries in the list are skipped"
Check ((Origin @('Supervertaler.MemoQ.Core.PreTranslateHelper.Run', 'MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.SyncLookupSingle')) -eq 'Grid') `
    "a method of ours that says PreTranslate decides nothing - only memoQ's frames count"
Check ((Origin @('Some.Other.Vendor.SyncLookupSingle')) -eq 'Unknown') "SyncLookupSingle outside memoQ's namespace: unknown"
Check ("$($detector.GetMethod('Current', $NonPublicStatic).Invoke($null, @()))" -eq 'Unknown') `
    "called from this harness, with no memoQ frames: unknown"

# ---- 2. the source keeps the shape the rule depends on ------------------------
$sessionSrc = Get-Content "$Bin\Supervertaler.MemoQ\SupervertalerSession.cs" -Raw
$batchSrc = Get-Content "$Bin\Supervertaler.MemoQ\Core\BatchTranslator.cs" -Raw
$arrays = [regex]::Matches($sessionSrc, 'TranslateCorrectSegment\(\s*Segment\[\][^)]*\)\s*\{(?<body>[^}]*)\}')
Check ($arrays.Count -eq 2 -and @($arrays | Where-Object { $_.Groups['body'].Value -match 'OriginIfNeeded\(\)' }).Count -eq 2) `
    "both array overloads read the origin where memoQ called them, before Task.Run"
Check ($batchSrc -match 'if \(context\.General\.BridgeMode && origin != LookupOrigin\.Grid\)') `
    "bridge mode captures everything except a recognised grid lookup"
$fallback = [regex]::Match($sessionSrc, 'catch \(Exception ex\)\s*\{(?<body>[\s\S]*?)falling back to one at a time')
Check ($fallback.Success -and $fallback.Groups['body'].Value -match 'BridgeMode && origin != LookupOrigin\.Grid' `
    -and $fallback.Groups['body'].Value -match 'return results') `
    "a failed batch in bridge mode is NOT retried row by row with the model (unless it was a grid lookup)"
Check ($batchSrc -match 'switch off \\"Pre-translate via Claude Desktop \(MCP\)\\"') `
    "the capture message names the box as the options dialog labels it"

# ---- 3. end to end, through memoQ's names on a real stack ---------------------
$builder = $common.GetType('MemoQ.Addins.Common.DataStructures.SegmentBuilder')
function Seg($t) { $builder.GetMethod('CreateFromString').Invoke($null, @($t)) }

$generalT = $main.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
$secureT  = $main.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings')
$settingsT = $main.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings')
$general = [Activator]::CreateInstance($generalT)
$generalT.GetProperty('BridgeMode').SetValue($general, $true)

# The shared settings file decides (run-harness.ps1 snapshots and restores it).
# A cloud provider, which has no key under the harness: a model attempt fails
# with a key error, never a request.
$sharedT = $main.GetType('Supervertaler.MemoQ.Core.SharedSettings')
$SharedProp = [Reflection.BindingFlags]'NonPublic,Public,Static'
$sharedT.GetProperty('BridgeMode', $SharedProp).SetValue($null, $true)
$sharedT.GetProperty('Provider', $SharedProp).SetValue($null, 'Anthropic')
$settings = $settingsT.GetMethod('Create').Invoke($null, @($general, [Activator]::CreateInstance($secureT)))

$engineT = $main.GetType('Supervertaler.MemoQ.SupervertalerMTEngine')
$engine = [Activator]::CreateInstance($engineT, [Reflection.BindingFlags]'Instance,Public,NonPublic', $null, @($settings, 'eng', 'nld'), $null)
$session = $engineT.GetMethod('CreateLookupSession').Invoke($engine, @())
$segT = (Seg 'x').GetType()
$segArrT = $segT.MakeArrayType()
$metaT = $mt.GetType('MemoQ.MTInterfaces.MTRequestMetadata')
$mArr  = $session.GetType().GetMethod('TranslateCorrectSegment', [Type[]]@($segArrT, $segArrT, $segArrT))
$mMeta = $session.GetType().GetMethod('TranslateCorrectSegment', [Type[]]@($segArrT, $segArrT, $segArrT, $metaT))

function OneRow($text) { $a = [Array]::CreateInstance($segT, 1); $a[0] = Seg $text; return ,$a }
function ArgsFor($method, $text) {
    # The leading comma keeps PowerShell from unrolling the argument list on return.
    if ($method -eq $mMeta) { return ,([object[]]@((OneRow $text), $null, $null, [Activator]::CreateInstance($metaT))) }
    return ,([object[]]@((OneRow $text), $null, $null))
}
function Captured($r) { ($null -eq $r.Translation) -and ($null -ne $r.Exception) -and ($r.Exception.Message -like '*No staged translation*') }
function WentToModel($r) { ($null -ne $r.Exception) -and ($r.Exception.Message -notlike '*No staged translation*') }

$grid = [MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager]
$job  = [MemoQ.Project.PreTranslateAndStatisticsJob]

foreach ($pair in @(@{ m = $mMeta; name = 'with metadata (what memoQ calls)' }, @{ m = $mArr; name = 'without metadata' })) {
    $r = ($grid::SyncLookupSingle($pair.m, $session, (ArgsFor $pair.m "Grid row $($pair.name).")))[0]
    Check (WentToModel $r) "bridge mode, grid lookup $($pair.name): went to the model, not captured ('$($r.Exception.Message)')"

    $r = ($job::preTranslateBatchMT($pair.m, $session, (ArgsFor $pair.m "Pre-translated row $($pair.name).")))[0]
    Check (Captured $r) "bridge mode, one-row Pre-translate $($pair.name): captured for Claude, no model call"

    $r = ($pair.m.Invoke($session, (ArgsFor $pair.m "Unrecognised caller $($pair.name).")))[0]
    Check (Captured $r) "bridge mode, caller not recognised $($pair.name): captured, as before the fix"
}

# A grid lookup in bridge mode is still visible to Claude: the row is captured
# into the store even though the model translates it.
Start-Sleep -Milliseconds 300
$hs = Get-Content 'D:\Supervertaler\memoq\runtime\bridge.json' -Raw | ConvertFrom-Json
$segs = Invoke-RestMethod -Uri "http://127.0.0.1:$($hs.port)/v1/segments" -Headers @{ Authorization = "Bearer $($hs.token)" } -Method Get
$sources = @($segs.segments | ForEach-Object { $_.source })
Write-Host "   (capture store answers with: $($sources -join ' | '))"
Check ($sources -contains 'Grid row without metadata.') `
    "the grid-looked-up row is still in the capture store for Claude"

# Each row once. A grid row is recorded twice on its way to the model - by the
# batch, then by the single-row step - and from 2026-09-20 the second record
# added it again (CaptureStore.Record's else had come to belong to the state line).
$repeated = @($sources | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
Check ($repeated.Count -eq 0) "the capture store lists every row once (repeated: $($repeated -join ' | '))"

# Bridge mode off: the origin changes nothing, a Pre-translate goes to the model.
$sharedT.GetProperty('BridgeMode', $SharedProp).SetValue($null, $false)
$r = ($job::preTranslateBatchMT($mMeta, $session, (ArgsFor $mMeta 'Pre-translated row, bridge mode off.')))[0]
Check (WentToModel $r) "bridge mode off: a Pre-translate goes to the model as always ('$($r.Exception.Message)')"

Write-Host ''
if ($fails -eq 0) { Write-Host "ALL PASS ($total)" } else { Write-Host "FAILED: $fails of $total"; exit 1 }
