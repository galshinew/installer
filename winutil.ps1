param([string]$AppFile)

$ErrorActionPreference = 'Stop'

$scriptUrl = 'https://raw.githubusercontent.com/galshinew/installer/main/winutil.ps1'
$jsonUrl = 'https://raw.githubusercontent.com/galshinew/installer/main/applications.json'
$script:selfPath = $MyInvocation.MyCommand.Path

function Get-Winget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c -and (Test-Path -LiteralPath $c.Source)) { return $c.Source }
    $alt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alt) { return $alt }
    return 'winget'
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relaunch-Elevated([string[]]$ids, [string]$mode) {
    $tmp = Join-Path $env:TEMP ("winutil-" + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $tmp -Value (@($mode) + $ids) -Encoding ASCII
    if ($PSScriptRoot) {
        $ps = Join-Path $PSScriptRoot 'winutil.ps1'
    } else {
        $ps = Join-Path $env:TEMP ("winutil-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Invoke-WebRequest -Uri $scriptUrl -OutFile $ps -UseBasicParsing
    }
    $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps`" -AppFile `"$tmp`""
    try {
        Start-Process powershell.exe -ArgumentList $a -Verb RunAs
        return $true
    } catch {
        return $false
    }
}

$autoIds = $null
$autoMode = 'install'
if ($AppFile) {
    if (Test-Path -LiteralPath $AppFile) {
        $lines = @(Get-Content -LiteralPath $AppFile)
        Remove-Item -LiteralPath $AppFile -ErrorAction SilentlyContinue
        if ($lines.Count -gt 0) { $autoMode = $lines[0].Trim() }
        $autoIds = @($lines | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if (-not (Test-Admin)) {
        if (Relaunch-Elevated $autoIds $autoMode) { exit 0 } else { Write-Host 'Elevation cancelled.'; Read-Host 'Press Enter to close'; exit 1 }
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$apps = $null
if ($PSScriptRoot) {
    $local = Join-Path $PSScriptRoot 'applications.json'
    if (Test-Path -LiteralPath $local) { $apps = Get-Content -LiteralPath $local -Raw -Encoding UTF8 | ConvertFrom-Json }
}
if (-not $apps) {
    try { $apps = Invoke-RestMethod -Uri $jsonUrl -TimeoutSec 5 } catch {}
}
if (-not $apps) {
    [System.Windows.Forms.MessageBox]::Show('Could not load the app list. Make sure the local server is running (start.cmd) or that applications.json is next to winutil.ps1.', 'WinUtil App Installer', 'OK', 'Error') | Out-Null
    exit 1
}

$categoryOrder = @('Browsers','Communications','Development','Document','Games','Microsoft Tools','Multimedia Tools','Pro Tools','Selfhosted Tools','Utilities')

$darkBg   = [System.Drawing.Color]::FromArgb(15,17,23)
$darkPanel= [System.Drawing.Color]::FromArgb(23,26,33)
$darkLine = [System.Drawing.Color]::FromArgb(42,47,58)
$lightTxt = [System.Drawing.Color]::FromArgb(230,230,230)
$mutedTxt = [System.Drawing.Color]::FromArgb(154,160,171)
$accent   = [System.Drawing.Color]::FromArgb(47,129,247)
$green    = [System.Drawing.Color]::FromArgb(35,134,54)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WinUtil App Installer'
$form.Size = New-Object System.Drawing.Size(880, 780)
$form.MinimumSize = New-Object System.Drawing.Size(760, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $darkBg
$form.ForeColor = $lightTxt

$title = New-Object System.Windows.Forms.Label
$title.Text = 'WinUtil App Installer'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $lightTxt
$title.Location = New-Object System.Drawing.Point(14, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = 'Expand a category and check the apps you want. Installed apps are marked in green - use Update for them.'
$sub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$sub.ForeColor = $mutedTxt
$sub.Location = New-Object System.Drawing.Point(15, 46)
$sub.AutoSize = $true
$form.Controls.Add($sub)

$search = New-Object System.Windows.Forms.TextBox
$search.Location = New-Object System.Drawing.Point(14, 70)
$search.Size = New-Object System.Drawing.Size(836, 26)
$search.Anchor = 'Top,Left,Right'
$search.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$search.BackColor = $darkPanel
$search.ForeColor = $lightTxt
$search.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($search)

$tv = New-Object System.Windows.Forms.TreeView
$tv.Location = New-Object System.Drawing.Point(14, 104)
$tv.Size = New-Object System.Drawing.Size(836, 350)
$tv.Anchor = 'Top,Bottom,Left,Right'
$tv.CheckBoxes = $true
$tv.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tv.BackColor = $darkPanel
$tv.ForeColor = $lightTxt
$tv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($tv)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(14, 462)
$progressBar.Size = New-Object System.Drawing.Size(836, 20)
$progressBar.Anchor = 'Bottom,Left,Right'
$progressBar.Style = 'Continuous'
$form.Controls.Add($progressBar)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(14, 490)
$log.Size = New-Object System.Drawing.Size(836, 150)
$log.Anchor = 'Bottom,Left,Right'
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$log.BackColor = $darkPanel
$log.ForeColor = $lightTxt
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Location = New-Object System.Drawing.Point(0, 652)
$bottom.Size = New-Object System.Drawing.Size(864, 86)
$bottom.Anchor = 'Bottom,Left,Right'
$bottom.BackColor = $darkBg
$form.Controls.Add($bottom)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = '0 apps selected'
$countLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$countLabel.ForeColor = $mutedTxt
$countLabel.Location = New-Object System.Drawing.Point(12, 8)
$countLabel.AutoSize = $true
$bottom.Controls.Add($countLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$statusLabel.ForeColor = $accent
$statusLabel.Location = New-Object System.Drawing.Point(430, 8)
$statusLabel.Size = New-Object System.Drawing.Size(420, 20)
$statusLabel.Anchor = 'Top,Right'
$statusLabel.TextAlign = 'MiddleRight'
$bottom.Controls.Add($statusLabel)

function Add-Button($name, $text, $x, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Name = $name
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 36)
    $b.Size = New-Object System.Drawing.Size(120, 30)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $darkLine
    $b.BackColor = $darkPanel
    $b.ForeColor = $lightTxt
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    if ($color) { $b.BackColor = $color; $b.FlatAppearance.BorderColor = $color }
    $bottom.Controls.Add($b)
    return $b
}

$btnInstall = Add-Button 'install' 'Install' 440 $accent
$btnUpdate  = Add-Button 'update'  'Update'  570 $green
$btnCopy    = Add-Button 'copy'   'Copy commands' 310 $null
$btnNone    = Add-Button 'none'   'None'     140 $null
$btnAll     = Add-Button 'all'    'Select all' 12 $null

function Get-Selected {
    $ids = @()
    foreach ($cn in $tv.Nodes) {
        foreach ($an in $cn.Nodes) {
            if ($an.Checked -and $an.Tag) { $ids += [string]$an.Tag }
        }
    }
    return $ids
}

function Update-Count {
    $n = @(Get-Selected).Count
    $countLabel.Text = "$n app(s) selected"
}

function Set-AllChecked([bool]$state) {
    $script:suppress = $true
    foreach ($cn in $tv.Nodes) { foreach ($an in $cn.Nodes) { $an.Checked = $state } }
    $script:suppress = $false
    Update-Count
}

$script:suppress = $false
$tv.Add_AfterCheck({
    param($s, $e)
    if ($script:suppress) { return }
    if ($e.Node.Nodes.Count -gt 0) {
        $script:suppress = $true
        foreach ($n in $e.Node.Nodes) { $n.Checked = $e.Node.Checked }
        $script:suppress = $false
    }
    Update-Count
})

$search.Add_TextChanged({
    $q = $search.Text.ToLower()
    foreach ($cn in $tv.Nodes) {
        $vis = 0
        foreach ($an in $cn.Nodes) {
            $tag = if ($an.Tag) { [string]$an.Tag } else { '' }
            $show = ($q -eq '' -or $an.Text.ToLower().Contains($q) -or $tag.ToLower().Contains($q))
            $an.Visible = $show
            if ($show) { $vis++ }
        }
        $cn.Visible = ($q -eq '' -or $vis -gt 0)
        if ($q -ne '') { $cn.Expand() }
    }
})

$installScript = {
    param($ids, $q, $wingetPath, $mode)
    foreach ($id in $ids) {
        $action = if ($mode -eq 'upgrade') { 'Updating' } else { 'Installing' }
        $q.Enqueue("=== ${action}: $id ===")
        if ($mode -eq 'upgrade') {
            & $wingetPath upgrade --id $id --accept-package-agreements --accept-source-agreements --silent --disable-interactivity 2>&1 | ForEach-Object { $q.Enqueue([string]$_) }
        } else {
            & $wingetPath install --id $id --accept-package-agreements --accept-source-agreements --silent --disable-interactivity 2>&1 | ForEach-Object { $q.Enqueue([string]$_) }
        }
        $q.Enqueue('@@DONE@@')
    }
    $q.Enqueue('@@ALLDONE@@')
}

$detectScript = {
    param($q, $wingetPath)
    $ids = New-Object System.Collections.Generic.HashSet[string]
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $wingetPath export -o $tmp --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if (Test-Path $tmp) {
            $data = Get-Content $tmp -Raw | ConvertFrom-Json
            foreach ($src in $data.Sources) {
                foreach ($pkg in $src.Packages) {
                    $id = [string]$pkg.PackageIdentifier
                    if ($id) { [void]$ids.Add($id.ToLower()) }
                }
            }
        }
    } catch {}
    finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    $q.Enqueue('@@INSTALLED@@:' + (($ids | Sort-Object) -join '|'))
}

$script:outQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:installPS = $null
$script:installRS = $null
$script:installHandle = $null
$script:detectPS = $null
$script:detectRS = $null
$script:detectHandle = $null
$script:completed = 0
$script:total = 0
$script:mode = 'install'
$script:finished = $false
$script:installedSet = $null
$script:installedIds = @()

function Start-Install([string[]]$ids, [string]$mode) {
    if (-not $ids -or $ids.Count -eq 0) { return }
    $script:mode = if ($mode) { $mode } else { 'install' }
    $script:total = $ids.Count
    $script:completed = 0
    $script:finished = $false
    $log.Clear()
    $progressBar.Value = 0
    $btnInstall.Enabled = $false
    $btnUpdate.Enabled = $false
    $btnInstall.Text = if ($script:mode -eq 'upgrade') { 'Updating...' } else { 'Installing...' }
    $verb = if ($script:mode -eq 'upgrade') { 'Updating' } else { 'Installing' }
    $statusLabel.Text = "$verb 0 of $($ids.Count)..."
    $script:installPS = [System.Management.Automation.PowerShell]::Create()
    $script:installRS = [runspacefactory]::CreateRunspace()
    $script:installPS.Runspace = $script:installRS
    $script:installRS.Open()
    $script:installPS.AddScript($installScript).AddArgument([string[]]$ids).AddArgument($script:outQ).AddArgument([string](Get-Winget)).AddArgument($script:mode) | Out-Null
    $script:installHandle = $script:installPS.BeginInvoke()
    $script:timer.Start()
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 200
$script:timer.Add_Tick({
    try {
        $line = $null
        while ($script:outQ.TryDequeue([ref]$line)) {
            if ($line -eq '@@DONE@@') { $script:completed++ }
            elseif ($line -eq '@@ALLDONE@@') { continue }
            elseif ($line -like '@@INSTALLED@@:*') {
                $set = New-Object System.Collections.Generic.HashSet[string]
                foreach ($x in ($line.Substring(14) -split '\|')) { if ($x) { [void]$set.Add($x) } }
                $script:installedSet = $set
                $script:installedIds = @()
                foreach ($cn in $tv.Nodes) {
                    foreach ($an in $cn.Nodes) {
                        if ($an.Tag -and $set.Contains(([string]$an.Tag).ToLower())) {
                            $an.Text = $an.Text + '  (installed)'
                            $an.ForeColor = $green
                            $script:installedIds += [string]$an.Tag
                        }
                    }
                }
                $statusLabel.Text = "$($script:installedIds.Count) app(s) already installed"
                try { $script:detectPS.Dispose() } catch {}
                try { $script:detectRS.Close() } catch {}
            }
            else { $log.AppendText($line + "`r`n") }
        }
        if ($script:total -gt 0) {
            $pct = [int](100 * $script:completed / $script:total)
            $progressBar.Value = $pct
            $verb = if ($script:mode -eq 'upgrade') { 'Updated' } else { 'Installed' }
            $statusLabel.Text = "$verb $($script:completed) of $($script:total)"
        }
        if ($script:installHandle -and $script:installHandle.IsCompleted -and -not $script:finished) {
            $script:finished = $true
            try { $script:installPS.Dispose() } catch {}
            try { $script:installRS.Close() } catch {}
            $progressBar.Value = 100
            $verb = if ($script:mode -eq 'upgrade') { 'apps updated' } else { 'apps installed' }
            $statusLabel.Text = "All done - $($script:total) $verb"
            $btnInstall.Enabled = $true
            $btnInstall.Text = 'Install'
            $btnUpdate.Enabled = $true
        }
    } catch {}
})

$btnAll.Add_Click({ Set-AllChecked $true })
$btnNone.Add_Click({ Set-AllChecked $false })

$btnCopy.Add_Click({
    $ids = @(Get-Selected)
    if ($ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one app first.', 'WinUtil') | Out-Null; return }
    $cmds = $ids | ForEach-Object { "winget install --id $_ --accept-package-agreements --accept-source-agreements --silent --disable-interactivity" }
    [System.Windows.Forms.Clipboard]::SetText($cmds -join "`r`n")
    $countLabel.Text = "$($ids.Count) commands copied to clipboard"
})

$btnInstall.Add_Click({
    $ids = @(Get-Selected)
    if ($ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one app first.', 'WinUtil') | Out-Null; return }
    if ($script:installedSet -and $script:installedSet.Count -gt 0) {
        $ids = @($ids | Where-Object { -not $script:installedSet.Contains($_.ToLower()) })
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('All selected apps are already installed. Use the Update button to update them.', 'WinUtil') | Out-Null
            return
        }
    }
    if (Test-Admin) {
        Start-Install $ids 'install'
    } else {
        if (Relaunch-Elevated $ids 'install') { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
})

$btnUpdate.Add_Click({
    if (-not $script:installedIds -or $script:installedIds.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps found yet. Wait a moment for the check to finish, or install apps first.', 'WinUtil') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Update $($script:installedIds.Count) installed app(s)?", 'WinUtil', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    if (Test-Admin) {
        Start-Install $script:installedIds 'upgrade'
    } else {
        if (Relaunch-Elevated $script:installedIds 'upgrade') { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
})

$form.Add_FormClosing({
    try { $script:timer.Stop() } catch {}
    if ($script:installHandle -and -not $script:installHandle.IsCompleted) {
        try { $script:installPS.Stop() } catch {}
    }
    if ($script:installPS) { try { $script:installPS.Dispose() } catch {} }
    if ($script:installRS) { try { $script:installRS.Close() } catch {} }
    if ($script:detectPS) { try { $script:detectPS.Dispose() } catch {} }
    if ($script:detectRS) { try { $script:detectRS.Close() } catch {} }
})

foreach ($cat in $categoryOrder) {
    $catApps = @($apps.PSObject.Properties | Where-Object { $_.Value.category -eq $cat } | Sort-Object { $_.Value.content })
    if ($catApps.Count -eq 0) { continue }
    $cn = New-Object System.Windows.Forms.TreeNode($cat)
    foreach ($app in $catApps) {
        $an = New-Object System.Windows.Forms.TreeNode($app.Value.content)
        $an.Tag = $app.Value.winget
        $an.ToolTipText = $app.Value.description
        $cn.Nodes.Add($an) | Out-Null
    }
    $tv.Nodes.Add($cn) | Out-Null
}
foreach ($cn in $tv.Nodes) { $cn.Collapse() }
Update-Count

$form.Add_Shown({
    $statusLabel.Text = 'Checking installed apps...'
    $script:detectPS = [System.Management.Automation.PowerShell]::Create()
    $script:detectRS = [runspacefactory]::CreateRunspace()
    $script:detectPS.Runspace = $script:detectRS
    $script:detectRS.Open()
    $script:detectPS.AddScript($detectScript).AddArgument($script:outQ).AddArgument([string](Get-Winget)) | Out-Null
    $script:detectHandle = $script:detectPS.BeginInvoke()
    $script:timer.Start()

    if ($script:autoIds -and $script:autoIds.Count -gt 0) {
        foreach ($cn in $tv.Nodes) {
            foreach ($an in $cn.Nodes) {
                if ($an.Tag -in $script:autoIds) { $an.Checked = $true }
            }
        }
        Update-Count
        Start-Install $script:autoIds $script:autoMode
    }
})

[System.Windows.Forms.Application]::Run($form)

if ($script:selfPath -and (Split-Path -Path $script:selfPath) -eq $env:TEMP) {
    Remove-Item -LiteralPath $script:selfPath -ErrorAction SilentlyContinue
}
