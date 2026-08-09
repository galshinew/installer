$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location -LiteralPath $root

if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    git init
    git remote add origin https://github.com/galshinew/installer.git
}

git add -A
$staged = git diff --cached --name-only
if ($staged) {
    git commit -m "Update $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
} else {
    Write-Host 'Nothing new to commit.'
}
git branch -M main
git push -u origin main
Write-Host 'Done. Files are live at https://raw.githubusercontent.com/galshinew/installer/main/'
