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
$tweaksUrl = "$baseUrl/tweaks.json"
$script:selfPath = $MyInvocation.MyCommand.Path

# For elevation we need a real, elevatable executable. Prefer the running host's
# real exe (PSHOME), fall back to System32 powershell.exe (always present & elevatable).
$realHost = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { $null }
if (-not $realHost -or -not (Test-Path -LiteralPath $realHost)) { $realHost = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $realHost -or -not (Test-Path -LiteralPath $realHost)) { $realHost = 'powershell.exe' }
$script:psHost = $realHost

function Get-Winget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c -and (Test-Path -LiteralPath $c.Source)) { return $c.Source }
    $alt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alt) { return $alt }
    return 'winget'
}

function Test-Winget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c -and (Test-Path -LiteralPath $c.Source)) { return $true }
    return (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))
}

function Ensure-Winget {
    if (Test-Winget) { return $true }
    $r = [System.Windows.Forms.MessageBox]::Show("Windows Package Manager (winget) is not installed on this PC.`nThis app uses winget to detect, install and update apps.`n`nInstall winget now? The Microsoft Store will open.", 'winget required', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return $false }
    try { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' } catch {}
    [System.Windows.Forms.MessageBox]::Show('The Microsoft Store should be open on the App Installer page. Click Install there, then come back and click OK.', 'winget') | Out-Null
    if (Test-Winget) { return $true }
    $r2 = [System.Windows.Forms.MessageBox]::Show('winget is still not detected. Check again?', 'winget', 'YesNo', 'Question')
    if ($r2 -eq 'Yes') { return (Ensure-Winget) }
    return $false
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
    $a = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$ps`" -AppFile `"$tmp`""
    try {
        Start-Process $script:psHost -ArgumentList $a -Verb RunAs
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
elseif (-not (Test-Admin) -and -not $env:WINUTIL_ELEVATED) {
    $env:WINUTIL_ELEVATED = '1'
    $ps = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'winutil.ps1' } else { $null }
    if (-not $ps) {
        $ps = Join-Path $env:TEMP ("winutil-" + [guid]::NewGuid().ToString('N') + '.ps1')
        try { Invoke-WebRequest -Uri $scriptUrl -OutFile $ps -UseBasicParsing } catch {}
    }
    if ($ps -and (Test-Path -LiteralPath $ps)) {
        try {
            Start-Process $script:psHost -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$ps`"" -Verb RunAs
            exit 0
        } catch {}
    }
}

# ---- history log ----
$script:historyFile = Join-Path (Join-Path $env:LOCALAPPDATA 'WinUtil') 'history.log'
function Write-History([string]$entry) {
    try {
        $dir = Split-Path -Path $script:historyFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0}`t{1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $entry
        Add-Content -LiteralPath $script:historyFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {}
}


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
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

# ---- tweaks catalog (from Chris Titus WinUtil) ----
$tweaksJson = $null
if ($PSScriptRoot) {
    $localT = Join-Path $PSScriptRoot 'tweaks.json'
    if (Test-Path -LiteralPath $localT) { $tweaksJson = Get-Content -LiteralPath $localT -Raw -Encoding UTF8 | ConvertFrom-Json }
}
if (-not $tweaksJson) {
    try { $tweaksJson = Invoke-RestMethod -Uri $tweaksUrl -TimeoutSec 5 } catch {}
}

$script:tweakOrder = @('Essential Tweaks','Customize Preferences','z__Advanced Tweaks - CAUTION','Performance Plans - NOT FOR LAPTOPS')
$script:tweaks = @{}
if ($tweaksJson) {
    foreach ($p in $tweaksJson.PSObject.Properties) {
        $t = $p.Value
        $script:tweaks[[string]$t.Content] = @{
            cat  = [string]$t.category
            desc = [string]$t.Description
            type = [string]$t.Type
            reg  = @(@($t.registry) | Where-Object { $_ } | ForEach-Object { @{p=[string]$_.Path; n=[string]$_.Name; v=[string]$_.Value; t=[string]$_.Type; o=[string]$_.OriginalValue} })
            svc  = @(@($t.service) | Where-Object { $_ } | ForEach-Object { @{n=[string]$_.Name; s=[string]$_.StartupType; o=[string]$_.OriginalType} })
            run  = @($t.InvokeScript | ForEach-Object { [string]$_ } | Where-Object { $_ })
            undo = @($t.UndoScript | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    }
}
if ($script:tweaks.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('Could not load the tweaks list. Make sure tweaks.json is next to winutil.ps1 or that the local server is running.', 'WinUtil App Installer', 'OK', 'Error') | Out-Null
}

# ---- theme ----
$cBg    = [System.Drawing.Color]::FromArgb(246,247,249)
$cPanel = [System.Drawing.Color]::White
$cLine  = [System.Drawing.Color]::FromArgb(222,227,236)
$cTxt   = [System.Drawing.Color]::FromArgb(30,35,43)
$cMuted = [System.Drawing.Color]::FromArgb(110,118,132)
$accent = [System.Drawing.Color]::FromArgb(37,99,235)
$green  = [System.Drawing.Color]::FromArgb(21,128,61)
$danger = [System.Drawing.Color]::FromArgb(203,30,45)
$amber  = [System.Drawing.Color]::FromArgb(217,119,6)
$amberDark = [System.Drawing.Color]::FromArgb(180,100,0)

$script:uiFont = 'Segoe UI'
try {
    if ((New-Object System.Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe UI Variable') { $script:uiFont = 'Segoe UI Variable' }
} catch {}

function Get-RoundedRegion([int]$w, [int]$h, [int]$r) {
    if ($r -lt 1) { return $null }
    $d = [math]::Min([math]::Min($r * 2, $w), $h)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $p.AddArc(0, $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return [System.Drawing.Region]::new($p)
}

function Set-Rounded($ctrl, [int]$radius) {
    try {
        $r = Get-RoundedRegion $ctrl.Width $ctrl.Height $radius
        if ($r) {
            if ($ctrl.Region) { try { $ctrl.Region.Dispose() } catch {} }
            $ctrl.Region = $r
        }
    } catch {}
}

$script:origColors = @{}
function Add-Hover([System.Windows.Forms.Button]$b) {
    $script:origColors[$b] = $b.BackColor
    $b.Add_MouseEnter({
        if ($this.Enabled) {
            $o = $script:origColors[$this]
            if ($o) {
                $this.BackColor = [System.Drawing.Color]::FromArgb(
                    [int][math]::Min(255, $o.R + (255 - $o.R) * 0.12),
                    [int][math]::Min(255, $o.G + (255 - $o.G) * 0.12),
                    [int][math]::Min(255, $o.B + (255 - $o.B) * 0.12))
            }
        }
    })
    $b.Add_MouseLeave({
        $o = $script:origColors[$this]
        if ($o) { $this.BackColor = $o }
    })
}

$script:sel = New-Object System.Collections.Generic.HashSet[object]
function Add-AppHover([System.Windows.Forms.Button]$b) {
    $script:origColors[$b] = $b.BackColor
    $b.Add_MouseEnter({
        if ($this.Enabled) {
            $o = $script:origColors[$this]
            if ($o) {
                $this.BackColor = [System.Drawing.Color]::FromArgb(
                    [int][math]::Min(255, $o.R + (255 - $o.R) * 0.1),
                    [int][math]::Min(255, $o.G + (255 - $o.G) * 0.1),
                    [int][math]::Min(255, $o.B + (255 - $o.B) * 0.1))
            }
        }
    })
    $b.Add_MouseLeave({
        $o = $script:origColors[$this]
        if ($o) { $this.BackColor = $o }
    })
}


# ---- window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'App Installer'
$form.ClientSize = New-Object System.Drawing.Size(880, 760)
$form.MinimumSize = New-Object System.Drawing.Size(760, 640)
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
$hTitle.Text = 'App Installer'
$hTitle.Font = New-Object System.Drawing.Font($script:uiFont, 16, [System.Drawing.FontStyle]::Bold)
$hTitle.ForeColor = [System.Drawing.Color]::White
$hTitle.Location = New-Object System.Drawing.Point(20, 7)
$hTitle.AutoSize = $true
$header.Controls.Add($hTitle)

$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = 'Install your favorite apps with winget'
$hSub.Font = New-Object System.Drawing.Font($script:uiFont, 9)
$hSub.ForeColor = [System.Drawing.Color]::FromArgb(210,225,255)
$hSub.Location = New-Object System.Drawing.Point(21, 38)
$hSub.AutoSize = $true
$header.Controls.Add($hSub)

$hVer = New-Object System.Windows.Forms.Label
$hVer.Text = 'v1.6'
$hVer.Font = New-Object System.Drawing.Font($script:uiFont, 9, [System.Drawing.FontStyle]::Bold)
$hVer.ForeColor = [System.Drawing.Color]::FromArgb(210,225,255)
$hVer.TextAlign = 'MiddleRight'
$hVer.Size = New-Object System.Drawing.Size(44, 20)
$hVer.Anchor = 'Top,Right'
$hVer.Location = New-Object System.Drawing.Point(($header.Width - $hVer.Width - 12), 8)
$header.Controls.Add($hVer)

# ---- tabs ----
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 64)
$tabs.Size = New-Object System.Drawing.Size(856, 490)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$form.Controls.Add($tabs)

$tabInstall = New-Object System.Windows.Forms.TabPage
$tabInstall.Text = 'Install'
$tabs.TabPages.Add($tabInstall)

$tabUpdate = New-Object System.Windows.Forms.TabPage
$tabUpdate.Text = 'Installed'
$tabs.TabPages.Add($tabUpdate)

$tabTweaks = New-Object System.Windows.Forms.TabPage
$tabTweaks.Text = 'Tweaks'
$tabs.TabPages.Add($tabTweaks)

$tabQueue = New-Object System.Windows.Forms.TabPage
$tabQueue.Text = 'Queue'
$tabs.TabPages.Add($tabQueue)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Log'
$tabs.TabPages.Add($tabLog)

# ---- Install tab ----
$search = New-Object System.Windows.Forms.TextBox
$search.Location = New-Object System.Drawing.Point(12, 10)
$search.Size = New-Object System.Drawing.Size(630, 26)
$search.Anchor = 'Top,Left,Right'
$search.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$search.BackColor = $cPanel
$search.ForeColor = $cTxt
$search.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tabInstall.Controls.Add($search)

$searchWm = New-Object System.Windows.Forms.Label
$searchWm.Text = 'Search apps...'
$searchWm.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$searchWm.ForeColor = $cMuted
$searchWm.Location = New-Object System.Drawing.Point(16, 12)
$searchWm.AutoSize = $true
$tabInstall.Controls.Add($searchWm)
$search.Add_Enter({ $searchWm.Visible = $false })
$search.Add_Leave({ if ($search.Text -eq '') { $searchWm.Visible = $true } })

$chipFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$chipFlow.Location = New-Object System.Drawing.Point(12, 42)
$chipFlow.Size = New-Object System.Drawing.Size(830, 62)
$chipFlow.AutoScroll = $false
$chipFlow.WrapContents = $true
$chipFlow.FlowDirection = 'LeftToRight'
$chipFlow.BackColor = $cBg
$tabInstall.Controls.Add($chipFlow)

$filterCombo = New-Object System.Windows.Forms.ComboBox
$filterCombo.DropDownStyle = 'DropDownList'
$filterCombo.Items.AddRange(@('All', 'Show only not installed', 'Show only installed'))
$filterCombo.SelectedIndex = 0
$filterCombo.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
$filterCombo.ForeColor = $cTxt
$filterCombo.BackColor = $cPanel
$filterCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$filterCombo.Anchor = 'Top,Right'
$filterCombo.Location = New-Object System.Drawing.Point(660, 10)
$filterCombo.Size = New-Object System.Drawing.Size(190, 26)
$tabInstall.Controls.Add($filterCombo)

$script:chips = @()
function Add-Chip([string]$label) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $label
    $c.Tag = $label
    $c.Size = New-Object System.Drawing.Size([math]::Max([int]($label.Length * 7.5 + 20), 42), 26)
    $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $c.FlatAppearance.BorderSize = 1
    $c.BackColor = $cPanel
    $c.ForeColor = $cTxt
    $c.FlatAppearance.BorderColor = $cLine
    $c.Font = New-Object System.Drawing.Font($script:uiFont, 8.25)
    $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 2, 3, 2)
    $c.Add_Click({ param($sender, $e) Select-Chip $sender })
    Set-Rounded $c 13
    $chipFlow.Controls.Add($c)
    $script:chips += $c
    return $c
}

function Interpolate-Color($c1, $c2, $t) {
    $r = [int]([math]::Round($c1.R + ($c2.R - $c1.R) * $t))
    $g = [int]([math]::Round($c1.G + ($c2.G - $c1.G) * $t))
    $b = [int]([math]::Round($c1.B + ($c2.B - $c1.B) * $t))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

$script:chipAnim = $null
$script:chipTimer = New-Object System.Windows.Forms.Timer
$script:chipTimer.Interval = 12
$script:chipTimer.Add_Tick({
    $a = $script:chipAnim
    if (-not $a) { $script:chipTimer.Stop(); return }
    $a.step++
    $t = $a.step / $a.steps
    if ($t -gt 1) { $t = 1 }
    $a.chip.BackColor = Interpolate-Color $cPanel $accent $t
    $a.chip.ForeColor = Interpolate-Color $cTxt ([System.Drawing.Color]::White) $t
    if ($t -ge 1) { $script:chipTimer.Stop() }
})

function Set-ChipUnselected($c) {
    $c.BackColor = $cPanel
    $c.ForeColor = $cTxt
    $c.FlatAppearance.BorderColor = $cLine
}

function Animate-ChipSelect($chip) {
    $chip.FlatAppearance.BorderColor = $accent
    $script:chipAnim = @{ chip = $chip; steps = 10; step = 0 }
    $script:chipTimer.Start()
}

function Select-Chip($chip) {
    if (-not $chip) { return }
    $newSel = [string]$chip.Tag
    if ($script:chipSel -eq $newSel -and $chip.BackColor.Equals($accent)) { return }
    foreach ($c in $script:chips) {
        if ($c -ne $chip) { Set-ChipUnselected $c }
    }
    $script:chipSel = $newSel
    Animate-ChipSelect $chip
    Apply-AppFilters
}

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Location = New-Object System.Drawing.Point(12, 110)
$flow.Size = New-Object System.Drawing.Size(830, 335)
$flow.AutoScroll = $true
$flow.WrapContents = $true
$flow.FlowDirection = 'LeftToRight'
$flow.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$flow.Padding = New-Object System.Windows.Forms.Padding(8)
$flow.BackColor = $cPanel
$tabInstall.Controls.Add($flow)

$script:tt = New-Object System.Windows.Forms.ToolTip
$script:tt.InitialDelay = 400

# ---- app context menu ----
$script:appMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miDetails = $script:appMenu.Items.Add('Details')
$miInstallNow = $script:appMenu.Items.Add('Install now')
$miHomepage = $script:appMenu.Items.Add('View homepage')
$miCopyId = $script:appMenu.Items.Add('Copy winget ID')
$miFav = $script:appMenu.Items.Add('Mark as favorite')
$script:appMenu.Add_Opening({
    $b = $script:appMenu.SourceControl
    if (-not $b -or -not $b.Tag) { return }
    $id = [string]$b.Tag
    $link = ''
    foreach ($p in $apps.PSObject.Properties) {
        if ([string]$p.Value.winget -eq $id) { $link = [string]$p.Value.link; break }
    }
    $script:appMenu.Items[2].Enabled = ($link -ne '')
    $script:appMenu.Items[4].Text = if ($script:favorites.Contains($id.ToLower())) { 'Remove from favorites' } else { 'Mark as favorite' }
})
$miDetails.Add_Click({
    $b = $script:appMenu.SourceControl
    if ($b) { Show-Details $b }
})
$miInstallNow.Add_Click({
    $b = $script:appMenu.SourceControl
    if ($b -and $b.Tag) { Start-InstallOne ([string]$b.Tag) }
})
$miHomepage.Add_Click({
    $b = $script:appMenu.SourceControl
    if ($b -and $b.Tag) {
        $link = ''
        foreach ($p in $apps.PSObject.Properties) { if ([string]$p.Value.winget -eq $b.Tag) { $link = [string]$p.Value.link; break } }
        if ($link) { try { Start-Process $link } catch {} }
    }
})
$miCopyId.Add_Click({
    $b = $script:appMenu.SourceControl
    if ($b -and $b.Tag) {
        try { [System.Windows.Forms.Clipboard]::SetText([string]$b.Tag) } catch { try { [string]$b.Tag | Set-Clipboard -ErrorAction Stop } catch {} }
    }
})
$miFav.Add_Click({
    $b = $script:appMenu.SourceControl
    if ($b -and $b.Tag) { Toggle-AppFavorite ([string]$b.Tag) }
})

function Update-AppButtonText([System.Windows.Forms.Button]$b) {
    if (-not $b -or -not $b.Tag) { return }
    $t = $b.Name
    if (-not $t) { $t = [string]$b.Tag }
    if ($script:favorites.Contains(([string]$b.Tag).ToLower())) { $t = [char]0x2605 + ' ' + $t }
    if ($script:installedSet -and $script:installedSet.Contains(([string]$b.Tag).ToLower())) { $t = $t + ' ' + [char]0x2713 }
    $b.Text = $t
}

function Toggle-AppFavorite([string]$id) {
    $key = $id.ToLower()
    if ($script:favorites.Contains($key)) { [void]$script:favorites.Remove($key) } else { [void]$script:favorites.Add($key) }
    Save-Favorites
    Update-AppButtonText (Get-AppButton $id)
    if ($script:chipSel -eq 'Favorites') { Apply-AppFilters }
    if ($script:detailsPanel -and $script:detailsPanel.Visible -and $script:detailsId -eq $key) { Update-DetailsFavBtn }
}

function Start-InstallOne([string]$id) {
    if (-not (Ensure-Winget)) { return }
    if ($script:installedSet -and $script:installedSet.Contains($id.ToLower())) {
        [System.Windows.Forms.MessageBox]::Show("$id is already installed. Use the Update tab instead.", 'WinUtil') | Out-Null
        return
    }
    if (Test-Admin) {
        Start-Install @($id) 'install'
    } else {
        if (Relaunch-Elevated @($id) 'install') { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
}

function Update-DetailsFavBtn {
    if (-not $script:detailsBtnFav) { return }
    if ($script:favorites.Contains([string]$script:detailsId)) {
        $script:detailsBtnFav.Text = [char]0x2605 + ' Remove from favorites'
    } else {
        $script:detailsBtnFav.Text = [char]0x2606 + ' Add to favorites'
    }
}

$script:catLabels = @{}
$script:catButtons = @{}
$script:buttonById = @{}

function Add-CategoryHeader([string]$cat, [int]$count = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = if ($count -gt 0) { "$cat ($count)" } else { $cat }
    $l.Font = New-Object System.Drawing.Font($script:uiFont, 11, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $accent
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size(794, 28)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 2)
    $flow.Controls.Add($l)
    $script:catLabels[$cat] = $l
    $script:catButtons[$cat] = @()
}

function Add-AppButton([string]$name, [string]$id, [string]$desc, [string]$cat, [string]$link) {
    $b = New-Object System.Windows.Forms.Button
    $b.Name = $name
    $b.Text = $name
    $b.Tag = $id
    $script:tt.SetToolTip($b, $desc)
    $b.Size = New-Object System.Drawing.Size(190, 42)
    $b.Margin = New-Object System.Windows.Forms.Padding(4)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $cLine
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = $cPanel
    $b.ForeColor = $cTxt
    $b.Font = New-Object System.Drawing.Font($script:uiFont, 9)
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
    $b.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
    $b.ContextMenuStrip = $script:appMenu
    $b.Add_Click({
        param($sender, $e)
        if ($script:sel.Contains($sender)) { Set-AppOn $sender $false } else { Set-AppOn $sender $true }
        Update-Count
    })
    $b.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne 'Right') { Hide-Details }
    })
    Set-Rounded $b 10
    Add-AppHover $b
    $flow.Controls.Add($b)
    $script:catButtons[$cat] += $b
    $script:idNames[$id] = $name
    $script:nameByIdLower[$id.ToLower()] = $name
    $script:buttonById[$id.ToLower()] = $b
    if ($link) {
        try {
            $d = ([uri]$link).Host
            if ($d) {
                [void]$script:uniqueDomains.Add($d)
                if (-not $script:domainButtons.ContainsKey($d)) { $script:domainButtons[$d] = @() }
                $script:domainButtons[$d] += $b
            }
        } catch {}
    }
    return $b
}

function Get-AppButton([string]$id) {
    if (-not $id) { return $null }
    if ($script:buttonById.ContainsKey($id.ToLower())) { return $script:buttonById[$id.ToLower()] }
    return $null
}

function Set-AppProcessing([System.Windows.Forms.Button]$b, [bool]$on) {
    if (-not $b) { return }
    if ($on) {
        $b.FlatAppearance.BorderSize = 2
        $b.FlatAppearance.BorderColor = $amber
    } else {
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $cLine
    }
}

$script:detailsPanel = $null
function Hide-Details {
    if ($script:detailsPanel) { $script:detailsPanel.Visible = $false }
}

function Show-Details([System.Windows.Forms.Button]$b) {
    $id = [string]$b.Tag
    $app = $null
    foreach ($p in $apps.PSObject.Properties) {
        if ([string]$p.Value.winget -eq $id) { $app = $p.Value; break }
    }
    if (-not $app) { return }
    if (-not $script:detailsPanel) {
        $p = New-Object System.Windows.Forms.Panel
        $p.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $p.BackColor = [System.Drawing.Color]::White
        $p.Size = New-Object System.Drawing.Size(380, 180)

        $script:detailsTitle = New-Object System.Windows.Forms.Label
        $script:detailsTitle.Font = New-Object System.Drawing.Font($script:uiFont, 11, [System.Drawing.FontStyle]::Bold)
        $script:detailsTitle.ForeColor = $cTxt
        $script:detailsTitle.Location = New-Object System.Drawing.Point(12, 8)
        $script:detailsTitle.AutoSize = $true
        $p.Controls.Add($script:detailsTitle)

        $script:detailsDesc = New-Object System.Windows.Forms.Label
        $script:detailsDesc.Font = New-Object System.Drawing.Font($script:uiFont, 9)
        $script:detailsDesc.ForeColor = $cTxt
        $script:detailsDesc.Location = New-Object System.Drawing.Point(12, 34)
        $script:detailsDesc.AutoSize = $true
        $script:detailsDesc.MaximumSize = New-Object System.Drawing.Size(356, 300)
        $p.Controls.Add($script:detailsDesc)

        $script:detailsInstalled = New-Object System.Windows.Forms.Label
        $script:detailsInstalled.Font = New-Object System.Drawing.Font($script:uiFont, 9, [System.Drawing.FontStyle]::Bold)
        $script:detailsInstalled.ForeColor = $green
        $script:detailsInstalled.Location = New-Object System.Drawing.Point(12, 34)
        $script:detailsInstalled.AutoSize = $true
        $p.Controls.Add($script:detailsInstalled)

        $script:detailsAvailable = New-Object System.Windows.Forms.Label
        $script:detailsAvailable.Font = New-Object System.Drawing.Font($script:uiFont, 9)
        $script:detailsAvailable.ForeColor = $cMuted
        $script:detailsAvailable.Location = New-Object System.Drawing.Point(12, 34)
        $script:detailsAvailable.AutoSize = $true
        $p.Controls.Add($script:detailsAvailable)

        $script:detailsLink = New-Object System.Windows.Forms.Label
        $script:detailsLink.Font = New-Object System.Drawing.Font($script:uiFont, 9)
        $script:detailsLink.ForeColor = $accent
        $script:detailsLink.Cursor = [System.Windows.Forms.Cursors]::Hand
        $script:detailsLink.Location = New-Object System.Drawing.Point(12, 0)
        $script:detailsLink.AutoSize = $true
        $script:detailsLink.MaximumSize = New-Object System.Drawing.Size(356, 60)
        $script:detailsLink.Add_Click({
            if ($script:detailsLink.Tag) { try { Start-Process ([string]$script:detailsLink.Tag) } catch {} }
        })
        $p.Controls.Add($script:detailsLink)

        $script:detailsBtnOpen = New-Object System.Windows.Forms.Button
        $script:detailsBtnOpen.Text = 'Open homepage'
        $script:detailsBtnOpen.Size = New-Object System.Drawing.Size(110, 28)
        $script:detailsBtnOpen.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:detailsBtnOpen.BackColor = $accent
        $script:detailsBtnOpen.FlatAppearance.BorderColor = $accent
        $script:detailsBtnOpen.ForeColor = [System.Drawing.Color]::White
        $script:detailsBtnOpen.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
        $script:detailsBtnOpen.Location = New-Object System.Drawing.Point(12, 0)
        $script:detailsBtnOpen.Add_Click({
            if ($script:detailsLink.Tag) { try { Start-Process ([string]$script:detailsLink.Tag) } catch {} }
        })
        Set-Rounded $script:detailsBtnOpen 6
        $p.Controls.Add($script:detailsBtnOpen)

        $script:detailsBtnClose = New-Object System.Windows.Forms.Button
        $script:detailsBtnClose.Text = 'Close'
        $script:detailsBtnClose.Size = New-Object System.Drawing.Size(70, 28)
        $script:detailsBtnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:detailsBtnClose.BackColor = [System.Drawing.Color]::White
        $script:detailsBtnClose.FlatAppearance.BorderColor = $cLine
        $script:detailsBtnClose.ForeColor = $cTxt
        $script:detailsBtnClose.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
        $script:detailsBtnClose.Location = New-Object System.Drawing.Point(12, 0)
        $script:detailsBtnClose.Add_Click({ Hide-Details })
        Set-Rounded $script:detailsBtnClose 6
        $p.Controls.Add($script:detailsBtnClose)

        $script:detailsBtnInstall = New-Object System.Windows.Forms.Button
        $script:detailsBtnInstall.Text = 'Install now'
        $script:detailsBtnInstall.Size = New-Object System.Drawing.Size(110, 28)
        $script:detailsBtnInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:detailsBtnInstall.BackColor = $green
        $script:detailsBtnInstall.FlatAppearance.BorderColor = $green
        $script:detailsBtnInstall.ForeColor = [System.Drawing.Color]::White
        $script:detailsBtnInstall.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
        $script:detailsBtnInstall.Location = New-Object System.Drawing.Point(12, 0)
        $script:detailsBtnInstall.Add_Click({ if ($script:detailsId) { Start-InstallOne $script:detailsId } })
        Set-Rounded $script:detailsBtnInstall 6
        Add-Hover $script:detailsBtnInstall
        $p.Controls.Add($script:detailsBtnInstall)

        $script:detailsBtnFav = New-Object System.Windows.Forms.Button
        $script:detailsBtnFav.Size = New-Object System.Drawing.Size(150, 28)
        $script:detailsBtnFav.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:detailsBtnFav.BackColor = [System.Drawing.Color]::White
        $script:detailsBtnFav.FlatAppearance.BorderColor = $cLine
        $script:detailsBtnFav.ForeColor = $cTxt
        $script:detailsBtnFav.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
        $script:detailsBtnFav.Location = New-Object System.Drawing.Point(12, 0)
        $script:detailsBtnFav.Add_Click({ if ($script:detailsId) { Toggle-AppFavorite $script:detailsId } })
        Set-Rounded $script:detailsBtnFav 6
        $p.Controls.Add($script:detailsBtnFav)

        $tabInstall.Controls.Add($p)
        $script:detailsPanel = $p
    }
    $script:detailsTitle.Text = [string]$app.content
    $script:detailsDesc.Text = [string]$app.description
    $script:detailsId = $id.ToLower()
    Update-DetailsFavBtn
    $key = $id.ToLower()
    if ($script:versionCache.ContainsKey($key)) {
        $v = $script:versionCache[$key]
        $script:detailsInstalled.Text = 'Installed: ' + $(if ($v.installed) { $v.installed } else { 'not installed' })
        $script:detailsAvailable.Text = 'Available: ' + $(if ($v.available) { $v.available } else { 'unknown' })
    } elseif (Test-Winget) {
        $script:detailsInstalled.Text = 'Installed: checking...'
        $script:detailsAvailable.Text = 'Available: checking...'
        Start-VersionQuery $id
    } else {
        $script:detailsInstalled.Text = 'Installed: n/a'
        $script:detailsAvailable.Text = 'Available: n/a'
    }
    $linkTxt = if ($app.link) { ([string]$app.link) } else { '' }
    $script:detailsLink.Text = $linkTxt
    $script:detailsLink.Tag = $linkTxt
    $script:detailsLink.Visible = ($linkTxt -ne '')
    $script:detailsDesc.Top = $script:detailsTitle.Bottom + 8
    $script:detailsInstalled.Top = $script:detailsDesc.Bottom + 8
    $script:detailsAvailable.Top = $script:detailsInstalled.Bottom + 2
    $script:detailsLink.Top = $script:detailsAvailable.Bottom + 8
    $script:detailsBtnOpen.Top = $script:detailsLink.Bottom + 10
    $script:detailsBtnClose.Top = $script:detailsBtnOpen.Top
    $script:detailsBtnClose.Left = $script:detailsBtnOpen.Right + 8
    $script:detailsBtnInstall.Top = $script:detailsBtnOpen.Bottom + 8
    $script:detailsBtnFav.Top = $script:detailsBtnInstall.Top
    $script:detailsBtnFav.Left = $script:detailsBtnInstall.Right + 8
    $script:detailsPanel.Height = $script:detailsBtnFav.Bottom + 10
    $scr = $b.PointToScreen([System.Drawing.Point]::Empty)
    $tabScr = $tabInstall.PointToScreen([System.Drawing.Point]::Empty)
    $x = $scr.X - $tabScr.X
    $y = $scr.Y - $tabScr.Y + $b.Height + 4
    $cw = $tabInstall.ClientSize.Width
    $ch = $tabInstall.ClientSize.Height
    if ($x + $script:detailsPanel.Width -gt $cw - 4) { $x = $cw - $script:detailsPanel.Width - 4 }
    if ($x -lt 4) { $x = 4 }
    if ($y + $script:detailsPanel.Height -gt $ch - 4) { $y = $scr.Y - $tabScr.Y - $script:detailsPanel.Height - 4 }
    if ($y -lt 4) { $y = 4 }
    $script:detailsPanel.Location = New-Object System.Drawing.Point($x, $y)
    $script:detailsPanel.Visible = $true
    $script:detailsPanel.BringToFront()
}
$flow.Add_Scroll({ Hide-Details })

# ---- Installed tab (update + uninstall + my list) ----
$ulv = New-Object System.Windows.Forms.ListView
$ulv.Location = New-Object System.Drawing.Point(12, 32)
$ulv.Size = New-Object System.Drawing.Size(830, 348)
$ulv.View = 'Details'
$ulv.FullRowSelect = $true
$ulv.HideSelection = $false
$ulv.Scrollable = $true
$ulv.CheckBoxes = $true
$ulv.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$ulv.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$ulv.BackColor = $cPanel
$ulv.ForeColor = $cTxt
$ulv.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$ulv.Columns.Add('App', 640) | Out-Null
$ulv.Columns.Add('Status', 120) | Out-Null
$tabUpdate.Controls.Add($ulv)

$updateCountLabel = New-Object System.Windows.Forms.Label
$updateCountLabel.Text = '0 installed · 0 selected'
$updateCountLabel.Font = New-Object System.Drawing.Font($script:uiFont, 9)
$updateCountLabel.ForeColor = $cMuted
$updateCountLabel.Location = New-Object System.Drawing.Point(12, 8)
$updateCountLabel.AutoSize = $true
$tabUpdate.Controls.Add($updateCountLabel)

$cbLeftovers = New-Object System.Windows.Forms.CheckBox
$cbLeftovers.Text = 'Remove program leftovers (AppData / ProgramData folders)'
$cbLeftovers.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
$cbLeftovers.ForeColor = $cTxt
$cbLeftovers.AutoSize = $true
$cbLeftovers.Location = New-Object System.Drawing.Point(12, 392)
$tabUpdate.Controls.Add($cbLeftovers)

$btnUninstallBig = New-Object System.Windows.Forms.Button
$btnUninstallBig.Text = 'Uninstall selected'
$btnUninstallBig.Size = New-Object System.Drawing.Size(250, 44)
$btnUninstallBig.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstallBig.BackColor = $danger
$btnUninstallBig.FlatAppearance.BorderColor = $danger
$btnUninstallBig.ForeColor = [System.Drawing.Color]::White
$btnUninstallBig.Font = New-Object System.Drawing.Font($script:uiFont, 11, [System.Drawing.FontStyle]::Bold)
$btnUninstallBig.Location = New-Object System.Drawing.Point(590, 392)
Set-Rounded $btnUninstallBig 8
Add-Hover $btnUninstallBig
$tabUpdate.Controls.Add($btnUninstallBig)

function Resize-Lists {
    $dw = $tabs.DisplayRectangle.Width
    $dh = $tabs.DisplayRectangle.Height
    $w = $dw - 24
    $search.Size = New-Object System.Drawing.Size(($w - 200), 26)
    $tsearch.Size = New-Object System.Drawing.Size($w, 26)
    $filterCombo.Location = New-Object System.Drawing.Point(($dw - 200), 13)
    $chipFlow.Size = New-Object System.Drawing.Size($w, 62)
    $flow.Location = New-Object System.Drawing.Point(12, 110)
    $flow.Size = New-Object System.Drawing.Size($w, ($dh - 124))
    $ulv.Size = New-Object System.Drawing.Size($w, ($dh - 108))
    $cbLeftovers.Location = New-Object System.Drawing.Point(12, ($dh - 64))
    $btnUninstallBig.Location = New-Object System.Drawing.Point(($dw - 264), ($dh - 64))
    $qlv.Size = New-Object System.Drawing.Size($w, ($dh - 12))
    $tflow.Location = New-Object System.Drawing.Point(12, 44)
    $tflow.Size = New-Object System.Drawing.Size($w, ($dh - 80))
    foreach ($cl in $script:catLabels.Values) { $cl.Width = $w - 48 }
    foreach ($cl in $tflow.Controls) {
        if ($cl -is [System.Windows.Forms.Label]) { $cl.Width = $w - 52 }
    }
    Set-Rounded $search 8
    Set-Rounded $tsearch 8
    Set-Rounded $flow 10
    Set-Rounded $tflow 10
    Set-Rounded $ulv 8
    Set-Rounded $qlv 8
    Set-Rounded $log 8
    Set-Rounded $logBox 8
}
$tabs.Add_Resize({ Resize-Lists })
$form.Add_Resize({ Resize-Lists })

# ---- Queue tab ----
$qlv = New-Object System.Windows.Forms.ListView
$qlv.Location = New-Object System.Drawing.Point(12, 10)
$qlv.Size = New-Object System.Drawing.Size(830, 348)
$qlv.View = 'Details'
$qlv.FullRowSelect = $true
$qlv.HideSelection = $false
$qlv.Scrollable = $true
$qlv.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$qlv.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$qlv.BackColor = $cPanel
$qlv.ForeColor = $cTxt
$qlv.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$qlv.Columns.Add('App', 600) | Out-Null
$qlv.Columns.Add('Status', 160) | Out-Null
$tabQueue.Controls.Add($qlv)


# ---- Tweaks tab ----
$tsearch = New-Object System.Windows.Forms.TextBox
$tsearch.Location = New-Object System.Drawing.Point(12, 10)
$tsearch.Size = New-Object System.Drawing.Size(830, 26)
$tsearch.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$tsearch.BackColor = $cPanel
$tsearch.ForeColor = $cTxt
$tsearch.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tabTweaks.Controls.Add($tsearch)

$tsearchWm = New-Object System.Windows.Forms.Label
$tsearchWm.Text = 'Search tweaks...'
$tsearchWm.Font = New-Object System.Drawing.Font($script:uiFont, 10)
$tsearchWm.ForeColor = $cMuted
$tsearchWm.Location = New-Object System.Drawing.Point(16, 12)
$tsearchWm.AutoSize = $true
$tabTweaks.Controls.Add($tsearchWm)
$tsearch.Add_Enter({ $tsearchWm.Visible = $false })
$tsearch.Add_Leave({ if ($tsearch.Text -eq '') { $tsearchWm.Visible = $true } })

$tflow = New-Object System.Windows.Forms.FlowLayoutPanel
$tflow.Location = New-Object System.Drawing.Point(12, 44)
$tflow.Size = New-Object System.Drawing.Size(830, 314)
$tflow.AutoScroll = $true
$tflow.WrapContents = $true
$tflow.FlowDirection = 'LeftToRight'
$tflow.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tflow.Padding = New-Object System.Windows.Forms.Padding(8)
$tflow.BackColor = $cPanel
$tabTweaks.Controls.Add($tflow)

$script:tweakChecks = @{}
function Add-TweakCategoryHeader([string]$cat, [int]$count = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = if ($count -gt 0) { "$cat ($count)" } else { $cat }
    $l.Tag = $cat
    $l.Font = New-Object System.Drawing.Font($script:uiFont, 11, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $accent
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size(794, 28)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 2)
    $tflow.Controls.Add($l)
}

$script:tweakGlyphs = @{
    'lock'                = [char]0xE72E
    'edge'                = [char]0xE774
    'brave'               = [char]0xE774
    'browser'             = [char]0xE774
    'onedrive'            = [char]0xE753
    'delivery optimization' = [char]0xE753
    'dns'                 = [char]0xE968
    'network'             = [char]0xE968
    'ipv6'                = [char]0xE968
    'teredo'              = [char]0xE968
    'telemetry'           = [char]0xEA18
    'privacy'             = [char]0xEA18
    'location'            = [char]0xEA18
    'activity history'    = [char]0xEA18
    'shutup'              = [char]0xEA18
    'adobe'               = [char]0xEA18
    'razer'               = [char]0xEA18
    'bitlocker'           = [char]0xE72E
    'companion'           = [char]0xEA18
    'wpbt'                = [char]0xEA18
    'warnings'            = [char]0xEA18
    'performance'         = [char]0xE7E8
    'hibernation'         = [char]0xE7E8
    'sleep'               = [char]0xE7E8
    'standby'             = [char]0xE7E8
    'num lock'            = [char]0xE7E8
    'power'               = [char]0xE7E8
    'start menu'          = [char]0xE80F
    'home and gallery'    = [char]0xE80F
    'utc'                 = [char]0xE823
    'date'                = [char]0xE823
    'folder'              = [char]0xE8B7
    'store'               = [char]0xE71B
    'outlook'             = [char]0xE715
    'search'              = [char]0xE721
    'bing'                = [char]0xE721
    'restore point'       = [char]0xE74E
    'temporary files'     = [char]0xE74D
    'cleanup'             = [char]0xE74E
    'background apps'     = [char]0xE71B
    'calendar'            = [char]0xE787
    'bsod'                = [char]0xE7BA
    'widgets'             = [char]0xE71B
    'ai'                  = [char]0xEA18
    'game mode'           = [char]0xE714
}
$script:glyphCache = @{}
function Get-TweakGlyph([string]$name) {
    $l = $name.ToLower()
    foreach ($k in $script:tweakGlyphs.Keys) {
        if ($l.Contains($k)) { return $script:tweakGlyphs[$k] }
    }
    return [char]0xE713
}
function New-GlyphImage([char]$glyph, $color) {
    $key = "$([int]$glyph)_$($color.ToArgb())"
    if ($script:glyphCache.ContainsKey($key)) { return $script:glyphCache[$key] }
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $brush = New-Object System.Drawing.SolidBrush($color)
    $font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 11)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $rect = New-Object System.Drawing.RectangleF(0, 0, 16, 16)
    $g.DrawString([string]$glyph, $font, $brush, $rect, $sf)
    $g.Dispose(); $font.Dispose(); $brush.Dispose(); $sf.Dispose()
    $script:glyphCache[$key] = $bmp
    return $bmp
}

function Set-TweakButtonOff([System.Windows.Forms.Button]$b) {
    $applied = Test-TweakApplied $script:tweaks[[string]$b.Tag]
    $b.BackColor = $cPanel
    if ($applied) {
        $b.ForeColor = $green
        $b.FlatAppearance.BorderColor = $green
        $b.Image = New-GlyphImage (Get-TweakGlyph $b.Text) $green
    } else {
        $b.ForeColor = $cTxt
        $b.FlatAppearance.BorderColor = $cLine
        $b.Image = New-GlyphImage (Get-TweakGlyph $b.Text) $cTxt
    }
}

$script:tweakMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miTweakPreview = $script:tweakMenu.Items.Add('Preview changes')
$miTweakApply = $script:tweakMenu.Items.Add('Apply')
$miTweakRevert = $script:tweakMenu.Items.Add('Revert')
$script:tweakMenu.Add_Opening({
    $tb = $script:tweakMenu.SourceControl
    if (-not $tb -or -not $tb.Tag) { return }
    $n = [string]$tb.Tag
    $script:tweakMenu.Items[0].Text = "Preview: $n"
    $script:tweakMenu.Items[1].Text = "Apply: $n"
    $script:tweakMenu.Items[2].Text = "Revert: $n"
})
$miTweakPreview.Add_Click({
    $tb = $script:tweakMenu.SourceControl
    if (-not $tb -or -not $tb.Tag) { return }
    $n = [string]$tb.Tag
    Show-PreviewDialog "Tweak preview - $n" ((Get-TweakPreview $n) -join "`r`n") $false | Out-Null
})
$miTweakApply.Add_Click({
    $tb = $script:tweakMenu.SourceControl
    if (-not $tb -or -not $tb.Tag) { return }
    $n = [string]$tb.Tag
    $items = @(Resolve-DnsItem @($n))
    Invoke-ApplyTweaks $items
})
$miTweakRevert.Add_Click({
    $tb = $script:tweakMenu.SourceControl
    if (-not $tb -or -not $tb.Tag) { return }
    $n = [string]$tb.Tag
    Invoke-ApplyTweaks @("$n=0")
})

function Add-TweakCheck([string]$name) {
    $t = $script:tweaks[$name]
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $name
    $b.Tag = $name
    $b.Size = New-Object System.Drawing.Size(190, 42)
    $b.Margin = New-Object System.Windows.Forms.Padding(4)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = $cPanel
    $b.ForeColor = $cTxt
    $b.FlatAppearance.BorderColor = $cLine
    $b.Font = New-Object System.Drawing.Font($script:uiFont, 9)
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
    $b.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
    $b.Image = New-GlyphImage (Get-TweakGlyph $name) $cTxt
    $b.ContextMenuStrip = $script:tweakMenu
    if ($t -and $t.desc) { $script:tt.SetToolTip($b, $t.desc) }
    $b.Add_Click({
        param($sender, $e)
        if ($sender.BackColor.Equals($accent)) {
            Set-TweakButtonOff $sender
        } else {
            $sender.BackColor = $accent
            $sender.ForeColor = [System.Drawing.Color]::White
            $sender.FlatAppearance.BorderColor = $accent
            $sender.Image = New-GlyphImage (Get-TweakGlyph $sender.Text) ([System.Drawing.Color]::White)
        }
    })
    Set-Rounded $b 8
    $tflow.Controls.Add($b)
    $script:tweakChecks[$name] = $b
}

foreach ($cat in $script:tweakOrder) {
    $names = @($script:tweaks.Keys | Where-Object { $script:tweaks[$_].cat -eq $cat } | Sort-Object)
    if ($names.Count -eq 0) { continue }
    Add-TweakCategoryHeader $cat $names.Count
    foreach ($n in $names) { Add-TweakCheck $n }
}

$tsearch.Add_TextChanged({
    $q = $tsearch.Text.ToLower()
    $curCat = $null
    $vis = @{}
    foreach ($ctrl in $tflow.Controls) {
        if ($ctrl -is [System.Windows.Forms.Label] -and $ctrl.Tag) {
            $curCat = [string]$ctrl.Tag
            $vis[$curCat] = 0
            $ctrl.Visible = ($q -eq '')
        } elseif ($ctrl -is [System.Windows.Forms.Button] -and $curCat) {
            $show = ($q -eq '' -or $ctrl.Text.ToLower().Contains($q))
            $ctrl.Visible = $show
            if ($show) { $vis[$curCat]++ }
        }
    }
    if ($q -ne '') {
        foreach ($ctrl in $tflow.Controls) {
            if ($ctrl -is [System.Windows.Forms.Label] -and $ctrl.Tag) {
                $ctrl.Visible = ($vis[[string]$ctrl.Tag] -gt 0)
            }
        }
    }
})

# ---- Log tab ----
$logPathLabel = New-Object System.Windows.Forms.Label
$logPathLabel.Location = New-Object System.Drawing.Point(12, 8)
$logPathLabel.AutoSize = $true
$logPathLabel.Font = New-Object System.Drawing.Font($script:uiFont, 9)
$logPathLabel.ForeColor = $cMuted
$logPathLabel.Text = "History file: $script:historyFile"
$tabLog.Controls.Add($logPathLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(12, 30)
$logBox.Size = New-Object System.Drawing.Size(830, 370)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.WordWrap = $false
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$logBox.BackColor = $cPanel
$logBox.ForeColor = $cTxt
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabLog.Controls.Add($logBox)

function Refresh-LogTab {
    $logBox.Text = ''
    try {
        if (Test-Path -LiteralPath $script:historyFile) {
            $logBox.Text = Get-Content -LiteralPath $script:historyFile -Raw -Encoding UTF8
        }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($logBox.Text)) { $logBox.Text = '(no history yet)' }
    $logPathLabel.Text = "History file: $script:historyFile"
}

# ---- progress + log ----
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(12, 558)
$progressBar.Size = New-Object System.Drawing.Size(856, 8)
$progressBar.Anchor = 'Bottom,Left,Right'
$progressBar.Style = 'Continuous'
$form.Controls.Add($progressBar)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 582)
$log.Size = New-Object System.Drawing.Size(856, 110)
$log.Anchor = 'Bottom,Left,Right'
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$log.BackColor = $cPanel
$log.ForeColor = $cTxt
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)

# ---- bottom bar ----
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Location = New-Object System.Drawing.Point(0, 700)
$bottom.Size = New-Object System.Drawing.Size(880, 60)
$bottom.Anchor = 'Bottom,Left,Right'
$bottom.BackColor = $cPanel
$form.Controls.Add($bottom)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = '0 apps selected'
$countLabel.Font = New-Object System.Drawing.Font($script:uiFont, 9)
$countLabel.ForeColor = $cMuted
$countLabel.Location = New-Object System.Drawing.Point(12, 6)
$countLabel.AutoSize = $true
$bottom.Controls.Add($countLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Font = New-Object System.Drawing.Font($script:uiFont, 9)
$statusLabel.ForeColor = $accent
$statusLabel.Location = New-Object System.Drawing.Point(430, 6)
$statusLabel.Size = New-Object System.Drawing.Size(436, 20)
$statusLabel.Anchor = 'Top,Right'
$statusLabel.TextAlign = 'MiddleRight'
$bottom.Controls.Add($statusLabel)

$script:bottomBtns = @()
function Add-BottomButton([string]$name, [string]$text, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Name = $name
    $b.Text = $text
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
    $b.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
    $b.Anchor = 'Bottom,Left'
    Set-Rounded $b 6
    Add-Hover $b
    $bottom.Controls.Add($b)
    $script:bottomBtns += $b
    return $b
}

$btnAll       = Add-BottomButton 'all'       'Select all'   $null
$btnNone      = Add-BottomButton 'none'      'None'         $null
$btnImport2   = Add-BottomButton 'import'    'Import list'  $accent
$btnInstall   = Add-BottomButton 'install'   'Install'      $accent
$btnUpdate    = Add-BottomButton 'update'    'Update'       $green
$btnUninstall = Add-BottomButton 'uninstall' 'Uninstall'    $danger
$btnUpdateAll = Add-BottomButton 'updateall' 'Update all'   $green
$btnSaveList2 = Add-BottomButton 'savelist'  'Save list'    $null
$btnCopyList2 = Add-BottomButton 'copylist'  'Copy list'    $null
$btnTweakApply  = Add-BottomButton 'tweakapply'  'Apply'    $green
$btnTweakRevert = Add-BottomButton 'tweakrevert' 'Revert'   $danger
$btnTweakPreview = Add-BottomButton 'tweakpreview' 'Preview' $null
$btnLogRefresh  = Add-BottomButton 'logrefresh'  'Refresh'  $null
$btnLogClear    = Add-BottomButton 'logclear'    'Clear log' $danger

$script:bottomSeps = @()
foreach ($i in 1..3) {
    $s = New-Object System.Windows.Forms.Panel
    $s.Width = 1
    $s.Height = 20
    $s.BackColor = $cLine
    $s.Anchor = 'Bottom,Left'
    $s.Visible = $false
    $bottom.Controls.Add($s)
    $script:bottomSeps += $s
}

$btnLogRefresh.Add_Click({
    Refresh-LogTab
    $countLabel.Text = "$(@(Get-Content -LiteralPath $script:historyFile -ErrorAction SilentlyContinue).Count) history line(s)"
})
$btnLogClear.Add_Click({
    if (-not (Test-Path -LiteralPath $script:historyFile)) { Refresh-LogTab; return }
    $r = [System.Windows.Forms.MessageBox]::Show('Clear the history log? This cannot be undone.', 'WinUtil', 'YesNo', 'Question', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Remove-Item -LiteralPath $script:historyFile -Force -ErrorAction Stop } catch {}
    Refresh-LogTab
    $countLabel.Text = '0 history line(s)'
})

$tabs.SelectedIndex = 0
$tabs.Add_SelectedIndexChanged({ Update-BottomBar; Refresh-Queue })

# ---- data model ----
$script:idNames = @{}
$script:nameByIdLower = @{}
$script:suppress = $false
$script:uniqueDomains = New-Object System.Collections.Generic.HashSet[string]
$script:domainButtons = @{}
$script:iconCache = @{}
$script:chipSel = 'All'
$script:queueRows = @{}
$script:leftoverMode = $false

$script:favoritesFile = Join-Path (Join-Path $env:LOCALAPPDATA 'WinUtil') 'favorites.txt'
$script:favorites = New-Object System.Collections.Generic.HashSet[string]
try {
    if (Test-Path -LiteralPath $script:favoritesFile) {
        foreach ($f in @(Get-Content -LiteralPath $script:favoritesFile -ErrorAction SilentlyContinue)) {
            $x = ([string]$f).Trim().ToLower()
            if ($x) { [void]$script:favorites.Add($x) }
        }
    }
} catch {}
function Save-Favorites {
    try { Set-Content -LiteralPath $script:favoritesFile -Value (@($script:favorites | Sort-Object)) -Encoding UTF8 } catch {}
}

function Get-Selected {
    $ids = @()
    foreach ($ctl in $flow.Controls) {
        if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag -and $script:sel.Contains($ctl)) {
            $ids += [string]$ctl.Tag
        }
    }
    return $ids
}

function Update-Count {
    $countLabel.Text = "$(@(Get-Selected).Count) app(s) selected"
    Set-UpdateEnabled
    Refresh-Queue
}

function Set-AppOn($b, [bool]$on) {
    if ($on) { [void]$script:sel.Add($b) } else { [void]$script:sel.Remove($b) }
    if ($on) {
        $b.BackColor = $accent
        $b.ForeColor = [System.Drawing.Color]::White
    } else {
        $b.BackColor = $cPanel
        $b.ForeColor = $cTxt
    }
    $script:origColors[$b] = $b.BackColor
}

function Set-AllChecked([bool]$state) {
    foreach ($ctl in $flow.Controls) {
        if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag) { Set-AppOn $ctl $state }
    }
    Update-Count
}

function Get-SelectedUpdate {
    $ids = @()
    foreach ($ctl in $flow.Controls) {
        if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag -and $script:sel.Contains($ctl)) {
            $ids += [string]$ctl.Tag
        }
    }
    $ids += @($ulv.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { [string]$_.Tag })
    return @($ids | Select-Object -Unique)
}

function Set-UpdateEnabled {
    $btnUpdate.Enabled = @(Get-SelectedUpdate).Count -gt 0
}

# ---- tweak engine ----
function Invoke-TweakScript([string[]]$lines) {
    foreach ($ln in $lines) {
        foreach ($l in ($ln -split "`r?`n")) {
            $s = $l.Trim()
            if ($s) { try { Invoke-Expression $s } catch {} }
        }
    }
}

function Invoke-WinUtilExplorerUpdate { param([string]$action) if ($action -eq 'restart') { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue } }

function Set-RegEntry($e) {
    try {
        if (-not $e.p -or -not $e.n -or -not $e.v) { return }
        if (-not (Test-Path -LiteralPath $e.p)) { New-Item -Path $e.p -Force | Out-Null }
        New-ItemProperty -Path $e.p -Name $e.n -Value ([string]$e.v) -PropertyType ([string]$e.t) -Force -ErrorAction Stop | Out-Null
    } catch {}
}

function Remove-RegEntry($e) {
    try {
        if ($e.o -and $e.o -ne '<RemoveEntry>') {
            Set-RegEntry @{p=$e.p; n=$e.n; v=$e.o; t=$e.t}
        } else {
            Remove-ItemProperty -Path $e.p -Name $e.n -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Set-SvcStartup([string]$name, [string]$type) {
    if ($type -eq 'Disable') { $type = 'Disabled' }
    try { Set-Service -Name $name -StartupType $type -ErrorAction Stop } catch {}
}

function Invoke-Tweak($t) {
    if ($t.reg) { foreach ($e in $t.reg) { if ($e.n -and $e.v) { Set-RegEntry $e } } }
    if ($t.svc) { foreach ($e in $t.svc) { if ($e.n) { Set-SvcStartup $e.n $e.s } } }
    if ($t.run) { Invoke-TweakScript $t.run }
}

function Undo-Tweak($t) {
    if ($t.reg) { foreach ($e in $t.reg) { if ($e.n) { Remove-RegEntry $e } } }
    if ($t.svc) { foreach ($e in $t.svc) { if ($e.n) { Set-SvcStartup $e.n $e.o } } }
    if ($t.undo) { Invoke-TweakScript $t.undo }
}

function Test-TweakApplied($t) {
    if (-not $t) { return $false }
    if ($t.reg) {
        $any = $false
        foreach ($e in $t.reg) {
            if (-not $e.n -or -not $e.p -or -not $e.v) { continue }
            $any = $true
            try {
                $cur = Get-ItemPropertyValue -Path $e.p -Name $e.n -ErrorAction Stop
                if ([string]$cur -ne [string]$e.v) { return $false }
            } catch { return $false }
        }
        if ($any) { return $true }
    }
    if ($t.svc) {
        $any = $false
        foreach ($e in $t.svc) {
            if (-not $e.n -or -not $e.s) { continue }
            $any = $true
            $svc = Get-Service -Name $e.n -ErrorAction SilentlyContinue
            $want = $e.s; if ($want -eq 'Disable') { $want = 'Disabled' }
            if (-not $svc -or $svc.StartType.ToString() -ne $want) { return $false }
        }
        if ($any) { return $true }
    }
    return $false
}

function Refresh-TweakStates {
    foreach ($b in $tflow.Controls) {
        if ($b -is [System.Windows.Forms.Button] -and $b.Tag) {
            if ($b.BackColor.Equals($accent)) { continue }
            Set-TweakButtonOff $b
        }
    }
}

function Set-MpoTweak {
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -Value 5 -PropertyType DWord -Force | Out-Null
    } catch {}
}
function Unset-MpoTweak {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'DisableOverlays' -ErrorAction SilentlyContinue
}

function Set-DnsTweak($extra) {
    $addrs = @($extra -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($addrs.Count -eq 0) { return }
    foreach ($n in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        try { Set-DnsClientServerAddress -InterfaceIndex $n.ifIndex -ServerAddresses $addrs -ErrorAction Stop } catch {}
    }
}
function Unset-DnsTweak {
    foreach ($n in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        try { Set-DnsClientServerAddress -InterfaceIndex $n.ifIndex -ResetServerAddresses -ErrorAction Stop } catch {}
    }
}

function Run-ShutUp10 {
    $tool = Join-Path $env:TEMP 'OOSU10.exe'
    if (-not (Test-Path -LiteralPath $tool)) {
        try { Invoke-WebRequest -Uri 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -OutFile $tool -UseBasicParsing } catch {}
    }
    if (Test-Path -LiteralPath $tool) { Start-Process $tool }
}

function Enable-UltimatePerformance {
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
    powercfg -setactive e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
}
function Disable-UltimatePerformance {
    powercfg -setactive SCHEME_BALANCED | Out-Null
    powercfg -delete e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
}

$script:tweakSpecial = @{
    'Multiplane Overlay'                      = @{ apply = { Set-MpoTweak }; revert = { Unset-MpoTweak } }
    'DNS - Set to:'                           = @{ apply = { param($x) Set-DnsTweak $x }; revert = { Unset-DnsTweak } }
    'O&O ShutUp10++ - Run'                    = @{ apply = { Run-ShutUp10 }; revert = {} }
    'Ultimate Performance Profile - Enable'   = @{ apply = { Enable-UltimatePerformance }; revert = { Disable-UltimatePerformance } }
    'Ultimate Performance Profile - Disable'  = @{ apply = { Disable-UltimatePerformance }; revert = { Enable-UltimatePerformance } }
}

function Apply-Tweaks([string[]]$items) {
    foreach ($item in $items) {
        $name = $item; $apply = $true; $extra = $null
        if ($item -match '^(.*)=(.*)$') { $name = $Matches[1]; $extra = $Matches[2]; $apply = ($extra -ne '0') }
        $t = $script:tweaks[$name]
        if (-not $t) { continue }
        $sp = $script:tweakSpecial[$name]
        if ($sp) {
            try {
                if ($apply) { & $sp.apply $extra } else { & $sp.revert $extra }
                Write-History ("tweak {0}: {1}" -f $(if ($apply) { 'applied' } else { 'reverted' }), $name)
            } catch {}
            continue
        }
        try {
            if ($apply) { Invoke-Tweak $t } else { Undo-Tweak $t }
            Write-History ("tweak {0}: {1}" -f $(if ($apply) { 'applied' } else { 'reverted' }), $name)
        } catch {}
    }
}

function Get-SelectedTweaks {
    @($tflow.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Tag -and $_.BackColor.Equals($accent) } | ForEach-Object { [string]$_.Tag })
}

function Get-TweakPreview([string]$name) {
    $t = $script:tweaks[$name]
    $lines = @()
    $lines += "Tweak: $name"
    if (-not $t) { return $lines }
    if ($t.desc) { $lines += "  $($t.desc)" }
    foreach ($e in $t.reg) {
        if (-not $e.p -or -not $e.n) { continue }
        $lines += "  Registry: $($e.p)"
        $lines += "    $($e.n) = $($e.v)  (Type: $($e.t))"
        if ($e.o -and $e.o -ne '<RemoveEntry>') { $lines += "    Original: $($e.o)" }
        else { $lines += '    Original: not present (entry removed)' }
    }
    foreach ($e in $t.svc) {
        if (-not $e.n) { continue }
        $lines += "  Service: $($e.n)  ->  $($e.s)"
        if ($e.o) { $lines += "    Original: $($e.o)" }
    }
    foreach ($s in $t.run) { $lines += "  Command: $s" }
    if ($t.undo -and $t.undo.Count -gt 0) { $lines += '  (has a revert script)' }
    if ($script:tweakSpecial.ContainsKey($name)) { $lines += '  (custom action - see script source)' }
    return $lines
}

function Show-PreviewDialog([string]$title, [string]$text, [bool]$withApply) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.Size = New-Object System.Drawing.Size(680, 500)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ShowInTaskbar = $false
    $f.BackColor = $cBg
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(12, 12)
    $tb.Size = New-Object System.Drawing.Size(640, 420)
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.WordWrap = $false
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $tb.BackColor = [System.Drawing.Color]::White
    $tb.ForeColor = $cTxt
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Text = $text
    Set-Rounded $tb 8
    $f.Controls.Add($tb)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(90, 30)
    $close.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $close.BackColor = $cPanel
    $close.FlatAppearance.BorderColor = $cLine
    $close.ForeColor = $cTxt
    $close.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
    $close.Location = New-Object System.Drawing.Point(562, 440)
    Set-Rounded $close 6
    $close.Add_Click({ $f.DialogResult = 'Cancel' })
    $f.Controls.Add($close)
    if ($withApply) {
        $apply = New-Object System.Windows.Forms.Button
        $apply.Text = 'Apply'
        $apply.Size = New-Object System.Drawing.Size(90, 30)
        $apply.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $apply.BackColor = $green
        $apply.FlatAppearance.BorderColor = $green
        $apply.ForeColor = [System.Drawing.Color]::White
        $apply.Font = New-Object System.Drawing.Font($script:uiFont, 9.5)
        $apply.Location = New-Object System.Drawing.Point(464, 440)
        Set-Rounded $apply 6
        Add-Hover $apply
        $apply.Add_Click({ $f.DialogResult = 'OK' })
        $f.Controls.Add($apply)
        $f.AcceptButton = $apply
    } else {
        $f.AcceptButton = $close
    }
    return $f.ShowDialog()
}

function Resolve-DnsItem([string[]]$items) {
    $out = @($items)
    if ($items -contains 'DNS - Set to:') {
        $addr = [Microsoft.VisualBasic.Interaction]::InputBox('Enter DNS servers separated by commas (blank resets back to DHCP):', 'DNS', '1.1.1.1,1.0.0.1')
        if ($addr.Trim() -eq '') {
            $out = @($out | ForEach-Object { if ($_ -eq 'DNS - Set to:') { 'DNS - Set to:=0' } else { $_ } })
        } else {
            $out = @($out | ForEach-Object { if ($_ -eq 'DNS - Set to:') { "DNS - Set to:=$($addr.Trim())" } else { $_ } })
        }
    }
    return ,$out
}

function Invoke-ApplyTweaks([string[]]$items) {
    if (Test-Admin) {
        Apply-Tweaks $items
        Refresh-TweakStates
        [System.Windows.Forms.MessageBox]::Show("Applied $($items.Count) tweak(s).", 'WinUtil') | Out-Null
    } else {
        if (Relaunch-Elevated $items 'tweak') { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
}

function Update-BottomBar {
    $groups = @()
    if ($tabs.SelectedIndex -eq 0)      { $groups = @(@($btnAll, $btnNone, $btnImport2), @($btnInstall, $btnUpdate, $btnUninstall, $btnUpdateAll)) }
    elseif ($tabs.SelectedIndex -eq 1)  { $groups = @(@($btnSaveList2, $btnCopyList2, $btnImport2), @($btnUpdateAll, $btnUpdate)) }
    elseif ($tabs.SelectedIndex -eq 2)  { $groups = @(@($btnAll, $btnNone), @($btnTweakPreview, $btnTweakApply, $btnTweakRevert)) }
    elseif ($tabs.SelectedIndex -eq 3)  { $groups = @(@($btnAll, $btnNone)) }
    elseif ($tabs.SelectedIndex -eq 4)  { $groups = @(@($btnLogRefresh, $btnLogClear)) }
    foreach ($b in $script:bottomBtns) { $b.Visible = $false }
    foreach ($s in $script:bottomSeps) { $s.Visible = $false }
    $x = 12
    for ($g = 0; $g -lt $groups.Count; $g++) {
        if ($g -gt 0 -and $g -le $script:bottomSeps.Count) {
            $s = $script:bottomSeps[$g - 1]
            $s.Visible = $true
            $s.Location = New-Object System.Drawing.Point($x, 34)
            $x += 22
        }
        foreach ($b in $groups[$g]) {
            $b.Visible = $true
            $b.Location = New-Object System.Drawing.Point($x, 26)
            $x += $b.Width + 8
        }
    }
    Set-UpdateEnabled
    if ($tabs.SelectedIndex -eq 4) { Refresh-LogTab }
}

function Update-UpdateCount {
    $checked = @($ulv.Items | Where-Object { $_.Checked }).Count
    $updateCountLabel.Text = "$($ulv.Items.Count) installed · $checked selected"
}

function Update-InstalledTab {
    $ulv.BeginUpdate()
    $ulv.Items.Clear()
    foreach ($id in $script:installedIds) {
        $name = $script:nameByIdLower[$id]
        if (-not $name) { $name = $id }
        $it = New-Object System.Windows.Forms.ListViewItem($name)
        $it.SubItems.Add('Installed') | Out-Null
        $it.Tag = $id
        $ulv.Items.Add($it) | Out-Null
    }
    $ulv.EndUpdate()
    Update-UpdateCount
}

function Refresh-Queue {
    if (-not $script:qlv) { return }
    $running = $false
    if ($script:installHandle -and -not $script:installHandle.IsCompleted) { $running = $true }
    elseif (-not $script:finished -and $script:total -gt 0) { $running = $true }
    $ids = @(Get-Selected)
    if ($script:extraIds -and $script:extraIds.Count -gt 0) { $ids = @($ids + $script:extraIds | Select-Object -Unique) }
    $script:qlv.BeginUpdate()
    try {
        if (-not $running) {
            $script:qlv.Items.Clear()
            $script:queueRows = @{}
            foreach ($id in $ids) {
                $name = $script:nameByIdLower[$id.ToLower()]
                if (-not $name) { $name = $id }
                $it = New-Object System.Windows.Forms.ListViewItem($name)
                $it.SubItems.Add('Queued') | Out-Null
                $it.Tag = $id
                $script:qlv.Items.Add($it) | Out-Null
                $script:queueRows[$id.ToLower()] = $it
            }
        } else {
            foreach ($id in $ids) {
                $key = $id.ToLower()
                if (-not $script:queueRows.ContainsKey($key)) {
                    $name = $script:nameByIdLower[$key]
                    if (-not $name) { $name = $id }
                    $it = New-Object System.Windows.Forms.ListViewItem($name)
                    $it.SubItems.Add('Waiting') | Out-Null
                    $it.Tag = $id
                    $script:qlv.Items.Add($it) | Out-Null
                    $script:queueRows[$key] = $it
                }
            }
        }
    } finally { $script:qlv.EndUpdate() }
}

function Update-QueueRow([string]$id, [string]$status) {
    $key = $id.ToLower()
    if (-not $script:queueRows.ContainsKey($key)) { return }
    $it = $script:queueRows[$key]
    if ($it.SubItems.Count -lt 2) { return }
    $it.SubItems[1].Text = $status
    $lc = $status.ToLower()
    $c = $green
    if ($lc -eq 'queued' -or $lc -eq 'waiting') { $c = $cMuted }
    elseif ($lc -eq 'failed') { $c = $danger }
    elseif ($lc -like 'installing*' -or $lc -like 'updating*' -or $lc -like 'uninstalling*') { $c = $amber }
    $it.SubItems[1].ForeColor = $c
}

function Remove-AppLeftovers([string]$id) {
    $name = $script:nameByIdLower[$id.ToLower()]
    if (-not $name) { $name = $id }
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA $name),
        (Join-Path $env:APPDATA $name),
        (Join-Path $env:PROGRAMDATA $name)
    )
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                Write-History ("leftovers removed: {0}" -f $d)
                $log.AppendText("Removed leftovers: $d`r`n")
            } catch {
                Write-History ("leftovers FAILED: {0}" -f $d)
                $log.AppendText("Could not remove leftovers: $d`r`n")
            }
        }
    }
}
$ulv.Add_ItemChecked({ Update-UpdateCount; Set-UpdateEnabled })

function Apply-AppFilters {
    $q = $search.Text.ToLower()
    $catSel = [string]$script:chipSel
    $filterMode = $filterCombo.SelectedItem
    $onlyNot = ($filterMode -eq 'Show only not installed') -and $script:installedSet
    $onlyInstalled = ($filterMode -eq 'Show only installed') -and $script:installedSet
    $favSel = ($catSel -eq 'Favorites')
    foreach ($cat in $categoryOrder) {
        if (-not $script:catButtons.ContainsKey($cat)) { continue }
        $vis = 0
        foreach ($b in $script:catButtons[$cat]) {
            $tag = if ($b.Tag) { [string]$b.Tag } else { '' }
            $isFav = $script:favorites.Contains($tag.ToLower())
            $isInstalled = $script:installedSet -and $script:installedSet.Contains($tag.ToLower())
            $show = ($q -eq '' -or $b.Text.ToLower().Contains($q) -or $tag.ToLower().Contains($q)) -and
                    (($favSel -and $isFav) -or ($catSel -eq 'All') -or ($catSel -eq $cat)) -and
                    (-not $onlyNot -or -not $isInstalled) -and
                    (-not $onlyInstalled -or $isInstalled)
            $b.Visible = $show
            if ($show) { $vis++ }
        }
        $script:catLabels[$cat].Visible = ($vis -gt 0)
    }
}
$search.Add_TextChanged({ Apply-AppFilters })
$filterCombo.Add_SelectedIndexChanged({ Apply-AppFilters })

# ---- background scripts ----
$installScript = {
    param($ids, $q, $wingetPath, $mode)
    foreach ($id in $ids) {
        $action = if ($mode -eq 'upgrade') { 'Updating' } elseif ($mode -eq 'uninstall') { 'Uninstalling' } else { 'Installing' }
        $q.Enqueue("=== ${action}: $id ===")
        if ($mode -eq 'upgrade') {
            & $wingetPath upgrade --id $id --accept-package-agreements --accept-source-agreements --silent --disable-interactivity 2>&1 | ForEach-Object { $q.Enqueue([string]$_) }
        } elseif ($mode -eq 'uninstall') {
            & $wingetPath uninstall --id $id --accept-source-agreements --silent --disable-interactivity 2>&1 | ForEach-Object { $q.Enqueue([string]$_) }
        } else {
            & $wingetPath install --id $id --accept-package-agreements --accept-source-agreements --silent --disable-interactivity 2>&1 | ForEach-Object { $q.Enqueue([string]$_) }
        }
        $code = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
        $q.Enqueue("@@DONE@@|$id|$code")
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
}

$versionScript = {
    param($q, $wingetPath, $id)
    $installed = ''; $available = ''
    try {
        $out = & $wingetPath show $id --accept-source-agreements --disable-interactivity 2>&1
        foreach ($line in $out) {
            $s = [string]$line
            if ($s -match '^\s*Installed Version:\s*(.+?)\s*$') {
                if (-not $installed) { $installed = $Matches[1].Trim() }
            }
            elseif ($s -match '^\s*Available Version:\s*(.+?)\s*$') { $available = $Matches[1].Trim() }
            elseif ($s -match '^\s*Version:\s*(.+?)\s*$') {
                if (-not $available) { $available = $Matches[1].Trim() }
            }
        }
        if (-not $installed) {
            $lst = & $wingetPath list $id --accept-source-agreements --disable-interactivity 2>&1
            foreach ($line in $lst) {
                $s = [string]$line
                if ($s -match '^\s*(Name|No installed)') { continue }
                $tokens = $s -split '\s+'
                $i = [array]::IndexOf($tokens, $id)
                if ($i -ge 0 -and $tokens.Count -gt $i + 1) { $installed = $tokens[$i + 1]; break }
            }
        }
    } catch {}
    if ($installed -eq 'Unknown') { $installed = '' }
    if ($available -eq 'Unknown') { $available = '' }
    $q.Enqueue("@@VERSION@@|$id|$installed|$available")
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
$script:versionCache = @{}
$script:verJobs = @()
$script:detailsId = $null
$script:completed = 0
$script:total = 0
$script:mode = 'install'
$script:finished = $false
$script:pulse = $false
$script:activeIds = @()
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

function Start-VersionQuery([string]$id) {
    $key = $id.ToLower()
    if ($script:versionCache.ContainsKey($key)) { return }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $rs = [runspacefactory]::CreateRunspace()
    $ps.Runspace = $rs
    $rs.Open()
    $ps.AddScript($versionScript).AddArgument($script:outQ).AddArgument([string](Get-Winget)).AddArgument($id) | Out-Null
    $h = $ps.BeginInvoke()
    $script:verJobs += @{ ps = $ps; rs = $rs; handle = $h; id = $key }
}

function Start-Install([string[]]$ids, [string]$mode) {
    if (-not $ids -or $ids.Count -eq 0) { return }
    $script:mode = if ($mode) { $mode } else { 'install' }
    $script:total = $ids.Count
    $script:completed = 0
    $script:finished = $false
    $script:activeIds = @($ids)
    $script:leftoverMode = [bool]$script:leftoverMode
    Write-History ("{0} batch started: {1} app(s)" -f $script:mode, $ids.Count)
    $log.Clear()
    $progressBar.Value = 0
    $btnInstall.Enabled = $false
    $btnUpdate.Enabled = $false
    $btnUpdateAll.Enabled = $false
    $btnUninstall.Enabled = $false
    Refresh-Queue
    foreach ($id in $script:activeIds) {
        Set-AppProcessing (Get-AppButton $id) $true
        Update-QueueRow $id 'Waiting'
    }
    $btnInstall.Text = if ($script:mode -eq 'upgrade') { 'Updating...' } elseif ($script:mode -eq 'uninstall') { 'Uninstalling...' } else { 'Installing...' }
    $verb = if ($script:mode -eq 'upgrade') { 'Updating' } elseif ($script:mode -eq 'uninstall') { 'Uninstalling' } else { 'Installing' }
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
            if ($line -like '@@DONE@@*') {
                $parts = $line -split '\|'
                $did = $script:activeIds[$script:completed]
                $code = -1
                if ($parts.Count -ge 3) { try { $code = [int]$parts[2] } catch { $code = -1 } }
                $ok = ($code -eq 0)
                if ($did) {
                    if ($ok) { Write-History ("{0} done: {1}" -f $script:mode, $did) }
                    else { Write-History ("{0} FAILED ({1}): {2}" -f $script:mode, $code, $did) }
                    Set-AppProcessing (Get-AppButton $did) $false
                    $finalSt = if ($script:mode -eq 'upgrade') { 'Updated' } elseif ($script:mode -eq 'uninstall') { 'Uninstalled' } else { 'Installed' }
                    Update-QueueRow $did $(if ($ok) { $finalSt } else { 'Failed' })
                    if ($script:leftoverMode -and $ok -and $script:mode -eq 'uninstall') { Remove-AppLeftovers $did }
                }
                $script:completed++
            }
            elseif ($line -eq '@@ALLDONE@@') { continue }
            elseif ($line -like '@@INSTALLED@@:*') {
                $set = New-Object System.Collections.Generic.HashSet[string]
                foreach ($x in ($line.Substring(14) -split '\|')) { if ($x) { [void]$set.Add($x) } }
                $script:installedSet = $set
                $script:allInstalled = @($set)
                $script:installedIds = @($set | Sort-Object)
                foreach ($ctl in $flow.Controls) {
                    if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag) {
                        Update-AppButtonText $ctl
                    }
                }
                Update-InstalledTab
                $statusLabel.Text = "$($script:installedIds.Count) app(s) already installed"
                Apply-AppFilters
                try { $script:detectPS.Dispose() } catch {}
                try { $script:detectRS.Close() } catch {}
            }
            elseif ($line -like '@@ICON@@|*') {
                $parts = $line.Substring(9).Split('|')
                if ($parts.Count -ge 2 -and $script:domainButtons.ContainsKey($parts[0])) {
                    try {
                        $ms = [System.IO.MemoryStream]::new([System.Convert]::FromBase64String($parts[1]))
                        $img = [System.Drawing.Image]::FromStream($ms)
                        $ico = New-Object System.Drawing.Bitmap(16, 16)
                        $g = [System.Drawing.Graphics]::FromImage($ico)
                        $g.InterpolationMode = 'HighQualityBicubic'
                        $g.DrawImage($img, 0, 0, 16, 16)
                        $g.Dispose()
                        $img.Dispose()
                        $ms.Dispose()
                        $script:iconCache[$parts[0]] = $ico
                        foreach ($btn in $script:domainButtons[$parts[0]]) { $btn.Image = $ico }
                    } catch {}
                }
            }
            elseif ($line -like '@@VERSION@@|*') {
                $parts = $line.Substring(12).Split('|')
                if ($parts.Count -ge 3) {
                    $key = $parts[0].ToLower()
                    $script:versionCache[$key] = @{ installed = $parts[1]; available = $parts[2] }
                    $done = @($script:verJobs | Where-Object { $_.id -eq $key })
                    if ($done) {
                        $script:verJobs = @($script:verJobs | Where-Object { $_.id -ne $key })
                        foreach ($x in $done) { try { $x.ps.Dispose() } catch {}; try { $x.rs.Close() } catch {} }
                    }
                    if ($script:detailsPanel -and $script:detailsPanel.Visible -and $script:detailsId -eq $key) {
                        $iv = if ($parts[1]) { $parts[1] } else { 'not installed' }
                        $av = if ($parts[2]) { $parts[2] } else { 'unknown' }
                        $script:detailsInstalled.Text = 'Installed: ' + $iv
                        $script:detailsAvailable.Text = 'Available: ' + $av
                    }
                }
            }
            else { $log.AppendText($line + "`r`n") }
        }
        if ($script:total -gt 0 -and -not $script:finished) {
            $pct = [int](100 * $script:completed / $script:total)
            $progressBar.Value = $pct
            $action = if ($script:mode -eq 'upgrade') { 'Updating' } elseif ($script:mode -eq 'uninstall') { 'Uninstalling' } else { 'Installing' }
            $verb = if ($script:mode -eq 'upgrade') { 'Updated' } elseif ($script:mode -eq 'uninstall') { 'Uninstalled' } else { 'Installed' }
            if ($script:completed -lt $script:activeIds.Count) {
                $cur = $script:activeIds[$script:completed]
                if ($cur) {
                    $curName = $script:nameByIdLower[$cur.ToLower()]
                    if (-not $curName) { $curName = $cur }
                    $statusLabel.Text = "$action $curName ($($script:completed) of $($script:total))"
                    Update-QueueRow $cur "$action..."
                }
            } else {
                $statusLabel.Text = "$verb $($script:completed) of $($script:total)"
            }
        }
        if ($script:activeIds -and $script:activeIds.Count -gt 0 -and -not $script:finished) {
            $script:pulse = -not $script:pulse
            $pulseColor = if ($script:pulse) { $amber } else { $amberDark }
            foreach ($id in $script:activeIds) {
                $b = Get-AppButton $id
                if ($b) { $b.FlatAppearance.BorderColor = $pulseColor }
            }
        }
        if ($script:installHandle -and $script:installHandle.IsCompleted -and -not $script:finished) {
            $script:finished = $true
            try { $script:installPS.Dispose() } catch {}
            try { $script:installRS.Close() } catch {}
            foreach ($id in $script:activeIds) { Set-AppProcessing (Get-AppButton $id) $false }
            $progressBar.Value = 100
            $verb = if ($script:mode -eq 'upgrade') { 'apps updated' } elseif ($script:mode -eq 'uninstall') { 'apps uninstalled' } else { 'apps installed' }
            $statusLabel.Text = "All done - $($script:total) $verb"
            Write-History ("{0} batch finished: {1} app(s)" -f $script:mode, $script:total)
            $btnInstall.Enabled = $true
            $btnInstall.Text = 'Install'
            Set-UpdateEnabled
            $btnUpdateAll.Enabled = $true
            $btnUninstall.Enabled = $true
            if ($script:mode -eq 'install' -or $script:mode -eq 'uninstall') {
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
    } elseif ($tabs.SelectedIndex -eq 2) {
        foreach ($b in $tflow.Controls) {
            if ($b -is [System.Windows.Forms.Button] -and $b.Tag) {
                $b.BackColor = $accent
                $b.ForeColor = [System.Drawing.Color]::White
                $b.FlatAppearance.BorderColor = $accent
            }
        }
    } else {
        Set-AllChecked $true
    }
})
$btnNone.Add_Click({
    if ($tabs.SelectedIndex -eq 1) {
        foreach ($it in $ulv.Items) { $it.Checked = $false }
        Update-UpdateCount
    } elseif ($tabs.SelectedIndex -eq 2) {
        foreach ($b in $tflow.Controls) {
            if ($b -is [System.Windows.Forms.Button] -and $b.Tag) { $b.BackColor = $cPanel }
        }
        Refresh-TweakStates
    } else {
        Set-AllChecked $false
    }
})

$btnSaveList2.Add_Click({
    if (-not $script:allInstalled -or $script:allInstalled.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps detected yet. Wait a moment for the check to finish.', 'WinUtil') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.FileName = 'installed-apps.txt'
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -eq 'OK') {
        Set-Content -LiteralPath $dlg.FileName -Value ($script:allInstalled -join "`r`n") -Encoding UTF8
        $statusLabel.Text = "Saved $($script:allInstalled.Count) app(s) to $($dlg.FileName)"
    }
})

$btnCopyList2.Add_Click({
    if (-not $script:allInstalled -or $script:allInstalled.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No installed apps detected yet. Wait a moment for the check to finish.', 'WinUtil') | Out-Null
        return
    }
    try {
        [System.Windows.Forms.Clipboard]::SetText(($script:allInstalled -join "`r`n"))
    } catch {
        try { $script:allInstalled -join "`r`n" | Set-Clipboard -ErrorAction Stop } catch {}
    }
    $statusLabel.Text = "$($script:allInstalled.Count) installed app(s) copied to clipboard"
})

$btnImport2.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $ids = @(Get-Content -LiteralPath $dlg.FileName | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No app IDs found in the file.', 'WinUtil') | Out-Null
        return
    }
    $script:suppress = $true
    foreach ($ctl in $flow.Controls) {
        if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag) { Set-AppOn $ctl $false }
    }
    $matched = 0
    foreach ($ctl in $flow.Controls) {
        if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag -and $ids -contains ([string]$ctl.Tag)) {
            Set-AppOn $ctl $true
            $matched++
        }
    }
    $script:suppress = $false
    $script:extraIds = @($ids | Where-Object { -not $script:catalogSet.Contains($_.ToLower()) })
    Update-Count
    $statusLabel.Text = "Imported $($ids.Count) app(s) ($matched from this list, $($script:extraIds.Count) extra). Switch to Install and press Install."
})

$btnInstall.Add_Click({
    if (-not (Ensure-Winget)) { return }
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
    if (-not (Ensure-Winget)) { return }
    $sel = @(Get-SelectedUpdate)
    if ($sel.Count -gt 0 -and $script:installedSet -and $script:installedSet.Count -gt 0) {
        $sel = @($sel | Where-Object { $script:installedSet.Contains($_.ToLower()) })
    }
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
    if (-not (Ensure-Winget)) { return }
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

function Confirm-StartUninstall([string[]]$ids) {
    if (-not $ids -or $ids.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select installed apps to uninstall first.', 'WinUtil') | Out-Null
        return
    }
    $msg = "Uninstall $($ids.Count) app(s)?"
    $icon = 'Question'
    if ($script:leftoverMode) {
        $msg += "`n`nProgram leftovers will also be removed - this deletes the AppData and ProgramData folders of these apps."
        $icon = 'Warning'
    }
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'WinUtil', 'YesNo', 'Question', $icon)
    if ($r -ne 'Yes') { return }
    if (Test-Admin) {
        Start-Install $ids 'uninstall'
    } else {
        $m = if ($script:leftoverMode) { 'uninstall+leftovers' } else { 'uninstall' }
        if (Relaunch-Elevated $ids $m) { $form.Close() }
        else { [System.Windows.Forms.MessageBox]::Show('Elevation cancelled.', 'WinUtil') | Out-Null }
    }
}

$btnUninstall.Add_Click({
    if (-not (Ensure-Winget)) { return }
    $ids = @(Get-SelectedUpdate)
    if ($ids.Count -gt 0 -and $script:installedSet -and $script:installedSet.Count -gt 0) {
        $ids = @($ids | Where-Object { $script:installedSet.Contains($_.ToLower()) })
    }
    $script:leftoverMode = $false
    Confirm-StartUninstall $ids
})

$btnUninstallBig.Add_Click({
    if (-not (Ensure-Winget)) { return }
    $ids = @($ulv.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { [string]$_.Tag })
    $script:leftoverMode = $cbLeftovers.Checked
    Confirm-StartUninstall $ids
})

$btnTweakApply.Add_Click({
    if ($script:tweaks.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Tweaks list could not be loaded.', 'WinUtil') | Out-Null; return }
    $items = @(Get-SelectedTweaks)
    if ($items.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one tweak first.', 'WinUtil') | Out-Null; return }
    $items = @(Resolve-DnsItem $items)
    Invoke-ApplyTweaks $items
})

$btnTweakPreview.Add_Click({
    if ($script:tweaks.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Tweaks list could not be loaded.', 'WinUtil') | Out-Null; return }
    $items = @(Get-SelectedTweaks)
    if ($items.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one tweak first.', 'WinUtil') | Out-Null; return }
    $lines = @()
    foreach ($n in $items) {
        $lines += Get-TweakPreview $n
        $lines += ''
    }
    $r = Show-PreviewDialog "Tweak preview ($($items.Count) selected)" ($lines -join "`r`n") $true
    if ($r -eq 'OK') {
        $items = @(Resolve-DnsItem $items)
        Invoke-ApplyTweaks $items
    }
})

$btnTweakRevert.Add_Click({
    if ($script:tweaks.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Tweaks list could not be loaded.', 'WinUtil') | Out-Null; return }
    $items = @(Get-SelectedTweaks | ForEach-Object { "$_=0" })
    if ($items.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one tweak first.', 'WinUtil') | Out-Null; return }
    $r = [System.Windows.Forms.MessageBox]::Show("Revert $($items.Count) tweak(s) back to their original settings?`n`nThis restores registry values, services and settings changed by the selected tweaks.", 'WinUtil', 'YesNo', 'Question', 'Warning')
    if ($r -ne 'Yes') { return }
    Invoke-ApplyTweaks $items
})

function Stop-LocalServer {
    try {
        # Kill by process command line
        $procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'server\.ps1' -and $_.ProcessId -ne $PID }
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
        }
        # Also kill anything listening on port 8765 (check all PIDs from netstat)
        $netstat = netstat -ano | Select-String ':8765'
        if ($netstat) {
            foreach ($line in $netstat) {
                $parts = $line -split '\s+'
                $pid = $parts[-1]
                if ($pid -and $pid -ne '0' -and $pid -ne $PID) {
                    try { Stop-Process -Id $pid -Force -ErrorAction Stop } catch {}
                }
            }
        }
        # Also try HTTP Server API cleanup
        try { netsh http delete urlacl url=http://localhost:8765/ } catch {}
    } catch {}
}

$form.Add_FormClosing({
    try { $script:timer.Stop() } catch {}
    try { $script:chipTimer.Stop() } catch {}
    if ($script:installHandle -and -not $script:installHandle.IsCompleted) {
        try { $script:installPS.Stop() } catch {}
    }
    if ($script:installPS) { try { $script:installPS.Dispose() } catch {} }
    if ($script:installRS) { try { $script:installRS.Close() } catch {} }
    if ($script:detectPS) { try { $script:detectPS.Dispose() } catch {} }
    if ($script:detectRS) { try { $script:detectRS.Close() } catch {} }
    if ($script:iconPS) { try { $script:iconPS.Dispose() } catch {} }
    if ($script:iconRS) { try { $script:iconRS.Close() } catch {} }
    foreach ($j in $script:verJobs) { try { $j.ps.Dispose() } catch {}; try { $j.rs.Close() } catch {} }
    $script:verJobs = @()
    Stop-LocalServer
})

# ---- build category buttons ----
foreach ($cat in $categoryOrder) {
    $catApps = @($apps.PSObject.Properties | Where-Object { $_.Value.category -eq $cat } | Sort-Object { $_.Value.content })
    if ($catApps.Count -eq 0) { continue }
    Add-CategoryHeader $cat $catApps.Count
    foreach ($app in $catApps) {
        Add-AppButton -name $app.Value.content -id ([string]$app.Value.winget) -desc $app.Value.description -cat $cat -link ([string]$app.Value.link) | Out-Null
    }
}
Add-Chip 'All' | Out-Null
foreach ($cat in $categoryOrder) {
    if ($script:catButtons.ContainsKey($cat)) { Add-Chip $cat | Out-Null }
}
Add-Chip 'Favorites' | Out-Null
$script:chipSel = 'All'
Select-Chip $script:chips[0]

$script:catalogSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($ctl in $flow.Controls) {
    if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag) {
        [void]$script:catalogSet.Add(([string]$ctl.Tag).ToLower())
        Update-AppButtonText $ctl
    }
}
Update-Count

$form.Add_Shown({
    Resize-Lists
    Update-BottomBar
    Refresh-TweakStates
    Refresh-Queue
    if ($script:autoMode -eq 'tweak') {
        Apply-Tweaks $script:autoIds
        [System.Windows.Forms.MessageBox]::Show("Tweaks applied: $($script:autoIds.Count)", 'WinUtil') | Out-Null
        $form.Close()
        return
    }
    if (-not (Ensure-Winget)) {
        $statusLabel.Text = 'winget not installed - Install and Update are unavailable'
        return
    }
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
        foreach ($ctl in $flow.Controls) {
            if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag -and $ctl.Tag -in $script:autoIds) {
                Set-AppOn $ctl $true
            }
        }
        Update-Count
        if ($script:autoMode -like 'uninstall*') {
            $script:leftoverMode = $script:autoMode -like '*leftovers*'
            Start-Install $script:autoIds 'uninstall'
        } else {
            Start-Install $script:autoIds $script:autoMode
        }
    }
})

[System.Windows.Forms.Application]::Run($form)

Stop-LocalServer

if ($script:selfPath -and (Split-Path -Path $script:selfPath) -eq $env:TEMP) {
    Remove-Item -LiteralPath $script:selfPath -ErrorAction SilentlyContinue
}

