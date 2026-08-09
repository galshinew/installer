param([string]$AppFile)

$ErrorActionPreference = 'Stop'

function Get-SourceBase {
    try {
        $r = Invoke-WebRequest -Uri 'http://localhost:8765/winutil.ps1' -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200 -and $r.RawContentLength -gt 1000) { return 'http://localhost:8765' }
    } catch {}
    return 'https://raw.githubusercontent.com/galshinew/installer/main'
}
$baseUrl = Get-SourceBase
$scriptUrl = "$baseUrl/winutil.ps1"
$jsonUrl = "$baseUrl/applications.json"
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

# ---- theme ----
$cBg    = [System.Drawing.Color]::FromArgb(246,247,249)
$cPanel = [System.Drawing.Color]::White
$cLine  = [System.Drawing.Color]::FromArgb(222,227,236)
$cTxt   = [System.Drawing.Color]::FromArgb(30,35,43)
$cMuted = [System.Drawing.Color]::FromArgb(110,118,132)
$accent = [System.Drawing.Color]::FromArgb(37,99,235)
$green  = [System.Drawing.Color]::FromArgb(21,128,61)

# ---- window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'WinUtil App Installer'
$form.ClientSize = New-Object System.Drawing.Size(880, 690)
$form.MinimumSize = New-Object System.Drawing.Size(720, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.ForeColor = $cTxt

# ---- header ----
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(880, 56)
$header.Anchor = 'Top,Left,Right'
$header.BackColor = $accent
$form.Controls.Add($header)

$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text = 'WinUtil App Installer'
$hTitle.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$hTitle.ForeColor = [System.Drawing.Color]::White
$hTitle.Location = New-Object System.Drawing.Point(20, 8)
$hTitle.AutoSize = $true
$header.Controls.Add($hTitle)

$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = 'Windows utility - powered by winget'
$hSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$hSub.ForeColor = [System.Drawing.Color]::FromArgb(210,225,255)
$hSub.Location = New-Object System.Drawing.Point(21, 36)
$hSub.AutoSize = $true
$header.Controls.Add($hSub)

# ---- tabs ----
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 64)
$tabs.Size = New-Object System.Drawing.Size(856, 416)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($tabs)

$tabInstall = New-Object System.Windows.Forms.TabPage
$tabInstall.Text = 'Install'
$tabs.TabPages.Add($tabInstall)

$tabUpdate = New-Object System.Windows.Forms.TabPage
$tabUpdate.Text = 'Update'
$tabs.TabPages.Add($tabUpdate)

$tabList = New-Object System.Windows.Forms.TabPage
$tabList.Text = 'My List'
$tabs.TabPages.Add($tabList)

# ---- Install tab ----
$search = New-Object System.Windows.Forms.TextBox
$search.Location = New-Object System.Drawing.Point(12, 10)
$search.Size = New-Object System.Drawing.Size(830, 26)
$search.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$search.BackColor = $cPanel
$search.ForeColor = $cTxt
$search.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tabInstall.Controls.Add($search)

$searchWm = New-Object System.Windows.Forms.Label
$searchWm.Text = 'Search apps...'
$searchWm.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$searchWm.ForeColor = $cMuted
$searchWm.Location = New-Object System.Drawing.Point(16, 12)
$searchWm.AutoSize = $true
$tabInstall.Controls.Add($searchWm)
$search.Add_Enter({ $searchWm.Visible = $false })
$search.Add_Leave({ if ($search.Text -eq '') { $searchWm.Visible = $true } })

$script:iconList = New-Object System.Windows.Forms.ImageList
$script:iconList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$script:iconList.ImageSize = New-Object System.Drawing.Size(20, 20)
$bmp = New-Object System.Drawing.Bitmap(20, 20)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($accent)
$g.Dispose()
$script:iconList.Images.Add($bmp) | Out-Null

$tv = New-Object System.Windows.Forms.TreeView
$tv.Location = New-Object System.Drawing.Point(12, 44)
$tv.Size = New-Object System.Drawing.Size(830, 348)
$tv.CheckBoxes = $true
$tv.Scrollable = $true
$tv.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tv.BackColor = $cPanel
$tv.ForeColor = $cTxt
$tv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$tv.ImageList = $script:iconList
$tabInstall.Controls.Add($tv)

# ---- Update tab ----
$ulv = New-Object System.Windows.Forms.ListView
$ulv.Location = New-Object System.Drawing.Point(12, 10)
$ulv.Size = New-Object System.Drawing.Size(830, 348)
$ulv.View = 'Details'
$ulv.FullRowSelect = $true
$ulv.HideSelection = $false
$ulv.Scrollable = $true
$ulv.CheckBoxes = $true
$ulv.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$ulv.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$ulv.BackColor = $cPanel
$ulv.ForeColor = $cTxt
$ulv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$ulv.Columns.Add('App', 600) | Out-Null
$ulv.Columns.Add('Status', 160) | Out-Null
$tabUpdate.Controls.Add($ulv)

function Resize-Lists {
    $dw = $tabs.DisplayRectangle.Width
    $dh = $tabs.DisplayRectangle.Height
    $w = $dw - 24
    $tvH = $dh - 46
    $ulvH = $dh - 12
    $search.Size = New-Object System.Drawing.Size($w, 26)
    $tv.Size = New-Object System.Drawing.Size($w, $tvH)
    $ulv.Size = New-Object System.Drawing.Size($w, $ulvH)
}
$tabs.Add_Resize({ Resize-Lists })
$form.Add_Resize({ Resize-Lists })

$updateCountLabel = New-Object System.Windows.Forms.Label
$updateCountLabel.Text = '0 installed app(s)'
$updateCountLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$updateCountLabel.ForeColor = $cMuted
$updateCountLabel.Location = New-Object System.Drawing.Point(12, 8)
$updateCountLabel.AutoSize = $true
$tabUpdate.Controls.Add($updateCountLabel)

# ---- My List tab ----
$infoLabel = New-Object System.Windows.Forms.Label
$infoLabel.Text = "Save or copy the list of apps installed on this PC, then import it here after a format or on another PC to reinstall everything in one go.`r`n`r`nThe list is a simple text file with one winget ID per line."
$infoLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$infoLabel.ForeColor = $cMuted
$infoLabel.Location = New-Object System.Drawing.Point(12, 12)
$infoLabel.Size = New-Object System.Drawing.Size(830, 60)
$tabList.Controls.Add($infoLabel)

$btnSaveList = New-Object System.Windows.Forms.Button
$btnSaveList.Text = 'Save list'
$btnSaveList.Location = New-Object System.Drawing.Point(12, 88)
$btnSaveList.Size = New-Object System.Drawing.Size(120, 32)
$btnSaveList.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSaveList.FlatAppearance.BorderColor = $cLine
$btnSaveList.BackColor = $cPanel
$btnSaveList.ForeColor = $cTxt
$btnSaveList.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$tabList.Controls.Add($btnSaveList)

$btnCopyList = New-Object System.Windows.Forms.Button
$btnCopyList.Text = 'Copy list'
$btnCopyList.Location = New-Object System.Drawing.Point(142, 88)
$btnCopyList.Size = New-Object System.Drawing.Size(120, 32)
$btnCopyList.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopyList.FlatAppearance.BorderColor = $cLine
$btnCopyList.BackColor = $cPanel
$btnCopyList.ForeColor = $cTxt
$btnCopyList.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$tabList.Controls.Add($btnCopyList)

$btnImport = New-Object System.Windows.Forms.Button
$btnImport.Text = 'Import list'
$btnImport.Location = New-Object System.Drawing.Point(272, 88)
$btnImport.Size = New-Object System.Drawing.Size(120, 32)
$btnImport.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnImport.FlatAppearance.BorderColor = $accent
$btnImport.BackColor = $accent
$btnImport.ForeColor = [System.Drawing.Color]::White
$btnImport.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$tabList.Controls.Add($btnImport)

$listStatus = New-Object System.Windows.Forms.Label
$listStatus.Text = ''
$listStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$listStatus.ForeColor = $cMuted
$listStatus.Location = New-Object System.Drawing.Point(12, 132)
$listStatus.AutoSize = $true
$tabList.Controls.Add($listStatus)

# ---- progress + log ----
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(12, 488)
$progressBar.Size = New-Object System.Drawing.Size(856, 18)
$progressBar.Anchor = 'Bottom,Left,Right'
$progressBar.Style = 'Continuous'
$form.Controls.Add($progressBar)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 512)
$log.Size = New-Object System.Drawing.Size(856, 110)
$log.Anchor = 'Bottom,Left,Right'
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$log.BackColor = $cPanel
$log.ForeColor = $cTxt
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)

# ---- bottom bar ----
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Location = New-Object System.Drawing.Point(0, 630)
$bottom.Size = New-Object System.Drawing.Size(880, 60)
$bottom.Anchor = 'Bottom,Left,Right'
$bottom.BackColor = $cPanel
$form.Controls.Add($bottom)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = '0 apps selected'
$countLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$countLabel.ForeColor = $cMuted
$countLabel.Location = New-Object System.Drawing.Point(12, 6)
$countLabel.AutoSize = $true
$bottom.Controls.Add($countLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$statusLabel.ForeColor = $accent
$statusLabel.Location = New-Object System.Drawing.Point(430, 6)
$statusLabel.Size = New-Object System.Drawing.Size(436, 20)
$statusLabel.Anchor = 'Top,Right'
$statusLabel.TextAlign = 'MiddleRight'
$bottom.Controls.Add($statusLabel)

function Add-Button($name, $text, $x, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Name = $name
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 26)
    $b.Size = New-Object System.Drawing.Size(100, 30)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    if ($color) {
        $b.BackColor = $color
        $b.FlatAppearance.BorderColor = $color
        $b.ForeColor = [System.Drawing.Color]::White
    } else {
        $b.BackColor = $cPanel
        $b.FlatAppearance.BorderColor = $cLine
        $b.ForeColor = $cTxt
    }
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $bottom.Controls.Add($b)
    return $b
}

$btnAll      = Add-Button 'all'      'Select all'  12   $null
$btnNone     = Add-Button 'none'     'None'        118  $null
$btnCopyList2 = Add-Button 'copylist' 'Copy list'  224  $null
$btnSaveList2 = Add-Button 'savelist' 'Save list'  330  $null
$btnImport2   = Add-Button 'import'   'Import list' 436  $null
$btnInstall   = Add-Button 'install'  'Install'    542  $accent
$btnUpdate    = Add-Button 'update'   'Update'     648  $green
$btnUpdateAll = Add-Button 'updateall' 'Update all' 754  $green

$tabs.SelectedIndex = 0

# ---- data model ----
$script:idNames = @{}
$script:domainNodes = @{}
$script:suppress = $false

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
    $countLabel.Text = "$(@(Get-Selected).Count) app(s) selected"
}

function Set-AllChecked([bool]$state) {
    $script:suppress = $true
    foreach ($cn in $tv.Nodes) { foreach ($an in $cn.Nodes) { $an.Checked = $state } }
    $script:suppress = $false
    Update-Count
}

function Get-SelectedUpdate {
    return @($ulv.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { [string]$_.Tag })
}

function Update-UpdateCount {
    $checked = @($ulv.Items | Where-Object { $_.Checked }).Count
    $updateCountLabel.Text = "$($ulv.Items.Count) installed · $checked selected for update"
}

function Update-InstalledTab {
    $ulv.BeginUpdate()
    $ulv.Items.Clear()
    foreach ($id in $script:installedIds) {
        $it = New-Object System.Windows.Forms.ListViewItem($script:idNames[$id])
        $it.SubItems.Add('Installed') | Out-Null
        $it.Tag = $id
        $ulv.Items.Add($it) | Out-Null
    }
    $ulv.EndUpdate()
    Update-UpdateCount
}
$ulv.Add_ItemChecked({ Update-UpdateCount })

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

# ---- background scripts ----
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

$iconScript = {
    param($q, $domains)
    foreach ($d in $domains) {
        try {
            $wc = New-Object Net.WebClient
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
            $bytes = $wc.DownloadData("https://www.google.com/s2/favicons?domain=$d&sz=64")
            $q.Enqueue('@@ICON@@|' + $d + '|' + [Convert]::ToBase64String($bytes))
        } catch {}
    }
    $q.Enqueue('@@ICONDONE@@')
}

$script:outQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:installPS = $null
$script:installRS = $null
$script:installHandle = $null
$script:detectPS = $null
$script:detectRS = $null
$script:detectHandle = $null
$script:iconPS = $null
$script:iconRS = $null
$script:iconHandle = $null
$script:completed = 0
$script:total = 0
$script:mode = 'install'
$script:finished = $false
$script:installedSet = $null
$script:installedIds = @()
$script:allInstalled = @()
$script:extraIds = @()
$script:catalogSet = $null

function Start-Detect {
    $script:detectPS = [System.Management.Automation.PowerShell]::Create()
    $script:detectRS = [runspacefactory]::CreateRunspace()
    $script:detectPS.Runspace = $script:detectRS
    $script:detectRS.Open()
    $script:detectPS.AddScript($detectScript).AddArgument($script:outQ).AddArgument([string](Get-Winget)) | Out-Null
    $script:detectHandle = $script:detectPS.BeginInvoke()
}

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
    $btnUpdateAll.Enabled = $false
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
                $script:allInstalled = @($set)
                $script:installedIds = @()
                foreach ($cn in $tv.Nodes) {
                    foreach ($an in $cn.Nodes) {
                        if ($an.Tag -and $set.Contains(([string]$an.Tag).ToLower())) {
                            if (-not $an.Text.EndsWith('(installed)')) { $an.Text = $an.Text + '  (installed)' }
                            $an.ForeColor = $green
                            $script:installedIds += [string]$an.Tag
                        }
                    }
                }
                Update-InstalledTab
                $statusLabel.Text = "$($script:installedIds.Count) app(s) already installed"
                try { $script:detectPS.Dispose() } catch {}
                try { $script:detectRS.Close() } catch {}
            }
            elseif ($line -like '@@ICON@@|*') {
                $parts = $line.Substring(9).Split('|')
                if ($parts.Count -ge 2 -and $script:domainNodes.ContainsKey($parts[0])) {
                    try {
                        $ms = [System.IO.MemoryStream]::new([System.Convert]::FromBase64String($parts[1]))
                        $img = [System.Drawing.Bitmap]::new($ms)
                        $copy = [System.Drawing.Bitmap]::new($img)
                        $ms.Dispose()
                        $img.Dispose()
                        $idx = $script:iconList.Images.Count
                        $script:iconList.Images.Add($copy) | Out-Null
                        foreach ($n in $script:domainNodes[$parts[0]]) { $n.ImageIndex = $idx }
                    } catch {}
                }
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
            $btnUpdateAll.Enabled = $true
            if ($script:mode -eq 'install') {
                $statusLabel.Text = 'All done - checking installed apps...'
                Start-Detect
            }
        }
    } catch {}
})

$btnAll.Add_Click({
    if ($tabs.SelectedIndex -eq 1) {
        foreach ($it in $ulv.Items) { $it.Checked = $true }
        Update-UpdateCount
    } else {
        Set-AllChecked $true
    }
})
$btnNone.Add_Click({
    if ($tabs.SelectedIndex -eq 1) {
        foreach ($it in $ulv.Items) { $it.Checked = $false }
        Update-UpdateCount
    } else {
        Set-AllChecked $false
    }
})

$btnCopyList.Add_Click({
    if (-not $script:allInstalled -or $script:allInstalled.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps detected yet. Wait a moment for the check to finish.', 'WinUtil') | Out-Null
        return
    }
    [System.Windows.Forms.Clipboard]::SetText(($script:allInstalled -join "`r`n"))
    $listStatus.Text = "$($script:allInstalled.Count) installed app(s) copied to clipboard"
})
$btnCopyList2.Add_Click({ $btnCopyList.PerformClick() })

$btnSaveList.Add_Click({
    if (-not $script:allInstalled -or $script:allInstalled.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps detected yet. Wait a moment for the check to finish.', 'WinUtil') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.FileName = 'installed-apps.txt'
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        Set-Content -LiteralPath $dlg.FileName -Value ($script:allInstalled -join "`r`n") -Encoding UTF8
        $listStatus.Text = "Saved $($script:allInstalled.Count) app(s) to $($dlg.FileName)"
    }
})
$btnSaveList2.Add_Click({ $btnSaveList.PerformClick() })

$btnImport.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $ids = @(Get-Content -LiteralPath $dlg.FileName | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No app IDs found in the file.', 'WinUtil') | Out-Null
        return
    }
    $script:suppress = $true
    $matched = 0
    foreach ($cn in $tv.Nodes) {
        foreach ($an in $cn.Nodes) {
            if ($an.Tag -and $ids -contains ([string]$an.Tag)) { $an.Checked = $true; $matched++ }
        }
    }
    $script:suppress = $false
    $script:extraIds = @($ids | Where-Object { -not $script:catalogSet.Contains($_.ToLower()) })
    Update-Count
    $listStatus.Text = "Imported $($ids.Count) app(s) ($matched from this list, $($script:extraIds.Count) extra). Switch to Install and press Install."
})
$btnImport2.Add_Click({ $btnImport.PerformClick() })

$btnInstall.Add_Click({
    $ids = @(Get-Selected)
    if ($script:extraIds -and $script:extraIds.Count -gt 0) { $ids = @($ids + $script:extraIds | Select-Object -Unique) }
    if ($ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one app first.', 'WinUtil') | Out-Null; return }
    if ($script:installedSet -and $script:installedSet.Count -gt 0) {
        $ids = @($ids | Where-Object { -not $script:installedSet.Contains($_.ToLower()) })
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('All selected apps are already installed. Use the Update button instead.', 'WinUtil') | Out-Null
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
    $sel = @(Get-SelectedUpdate)
    if ($sel.Count -eq 0) {
        if (-not $script:installedIds -or $script:installedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No installed apps found yet. Wait a moment for the check to finish, or install apps first.', 'WinUtil') | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show("No apps selected for update. Update all $($script:installedIds.Count) installed app(s)?", 'WinUtil', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $sel = @($script:installedIds)
    }
    if (Test-Admin) {
        Start-Install $sel 'upgrade'
    } else {
        if (Relaunch-Elevated $sel 'upgrade') { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
})

$btnUpdateAll.Add_Click({
    if (-not $script:installedIds -or $script:installedIds.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps found yet. Wait a moment for the check to finish, or install apps first.', 'WinUtil') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Update all $($script:installedIds.Count) installed app(s)?", 'WinUtil', 'YesNo', 'Question')
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
    if ($script:iconPS) { try { $script:iconPS.Dispose() } catch {} }
    if ($script:iconRS) { try { $script:iconRS.Close() } catch {} }
})

# ---- build tree + icon domain map ----
$script:uniqueDomains = New-Object System.Collections.Generic.HashSet[string]
foreach ($cat in $categoryOrder) {
    $catApps = @($apps.PSObject.Properties | Where-Object { $_.Value.category -eq $cat } | Sort-Object { $_.Value.content })
    if ($catApps.Count -eq 0) { continue }
    $cn = New-Object System.Windows.Forms.TreeNode($cat)
    $cn.NodeFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    foreach ($app in $catApps) {
        $an = New-Object System.Windows.Forms.TreeNode($app.Value.content)
        $an.Tag = [string]$app.Value.winget
        $an.ToolTipText = $app.Value.description
        $an.ImageIndex = 0
        $cn.Nodes.Add($an) | Out-Null
        $script:idNames[[string]$app.Value.winget] = $app.Value.content
        if ($app.Value.link) {
            try {
                $d = ([uri]$app.Value.link).Host
                if ($d) {
                    [void]$script:uniqueDomains.Add($d)
                    if (-not $script:domainNodes.ContainsKey($d)) { $script:domainNodes[$d] = @() }
                    $script:domainNodes[$d] += $an
                }
            } catch {}
        }
    }
    $tv.Nodes.Add($cn) | Out-Null
}
foreach ($cn in $tv.Nodes) { $cn.Collapse() }

$script:catalogSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($cn in $tv.Nodes) {
    foreach ($an in $cn.Nodes) {
        if ($an.Tag) { [void]$script:catalogSet.Add(([string]$an.Tag).ToLower()) }
    }
}
Update-Count

$form.Add_Shown({
    Resize-Lists
    $statusLabel.Text = 'Checking installed apps...'
    Start-Detect

    if ($script:uniqueDomains.Count -gt 0) {
        $script:iconPS = [System.Management.Automation.PowerShell]::Create()
        $script:iconRS = [runspacefactory]::CreateRunspace()
        $script:iconPS.Runspace = $script:iconRS
        $script:iconRS.Open()
        $script:iconPS.AddScript($iconScript).AddArgument($script:outQ).AddArgument(@($script:uniqueDomains)) | Out-Null
        $script:iconHandle = $script:iconPS.BeginInvoke()
    }

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
