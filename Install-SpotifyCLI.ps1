function Install-SpotifyCLI {
    <#
    .SYNOPSIS
    Complete Spotify CLI installation for new computers
    
    .DESCRIPTION
    Installs and configures Spotify CLI with all dependencies and profile setup
    
    .PARAMETER Force
    Force reinstallation even if already installed
    #>
    [CmdletBinding()]
    param([switch]$Force)
    
    Write-Host "🎵 Spotify CLI - Complete Installation" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "🚀 Starting installation process..." -ForegroundColor Green
    Write-Host ""
    
    try {
        # Check PowerShell version
        Write-Host "[1/6] 🔍 Checking PowerShell compatibility..." -ForegroundColor Yellow
        $psVersion = $PSVersionTable.PSVersion
        Write-Host "   PowerShell Version: $($psVersion.ToString())" -ForegroundColor Gray
        
        if ($psVersion.Major -lt 5) {
            throw "PowerShell 5.0 or higher is required. Current version: $($psVersion.ToString())"
        }
        Write-Host "✅ PowerShell version compatible" -ForegroundColor Green
        
        # Check execution policy
        Write-Host "[2/6] 🔍 Checking execution policy..." -ForegroundColor Yellow
        $executionPolicy = Get-ExecutionPolicy -Scope CurrentUser
        Write-Host "   Current execution policy: $executionPolicy" -ForegroundColor Gray
        
        if ($executionPolicy -eq "Restricted") {
            Write-Host "⚠️ Execution policy is Restricted. Attempting to set to RemoteSigned..." -ForegroundColor Yellow
            try {
                Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
                Write-Host "✅ Execution policy updated to RemoteSigned" -ForegroundColor Green
            } catch {
                Write-Host "❌ Failed to update execution policy. Please run as administrator." -ForegroundColor Red
                throw "Execution policy update failed"
            }
        } else {
            Write-Host "✅ Execution policy allows script execution" -ForegroundColor Green
        }
        
        # Install optional modules
        Write-Host "[3/6] 📦 Installing optional modules..." -ForegroundColor Yellow
        try {
            $installedModule = Get-Module -Name "BurntToast" -ListAvailable
            if (-not $installedModule -or $Force) {
                Write-Host "   Installing BurntToast for notifications..." -ForegroundColor Gray
                Install-Module -Name "BurntToast" -Force -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue
                Write-Host "   ✅ BurntToast installed" -ForegroundColor Green
            } else {
                Write-Host "   ✅ BurntToast already installed" -ForegroundColor Green
            }
        } catch {
            Write-Host "   ⚠️ BurntToast installation failed (optional)" -ForegroundColor Yellow
        }
        
        # Setup directories
        Write-Host "[4/6] 📁 Setting up directories..." -ForegroundColor Yellow
        
        # Create app data directory
        $appDataDir = Join-Path $env:APPDATA "SpotifyCLI"
        if (-not (Test-Path $appDataDir)) {
            New-Item -ItemType Directory -Path $appDataDir -Force | Out-Null
            Write-Host "   ✅ Created app data directory: $appDataDir" -ForegroundColor Green
        } else {
            Write-Host "   ✅ App data directory exists" -ForegroundColor Green
        }
        
        # Setup PowerShell module directory
        $userModulesPath = Join-Path (Split-Path $PROFILE -Parent) "Modules"
        $spotifyModulePath = Join-Path $userModulesPath "SpotifyCommands"
        
        if (Test-Path $spotifyModulePath) {
            if ($Force) {
                Remove-Item $spotifyModulePath -Recurse -Force
                Write-Host "   ✅ Removed old module (Force specified)" -ForegroundColor Green
            } else {
                Write-Host "   ⚠️ Module already exists, use -Force to reinstall" -ForegroundColor Yellow
            }
        }
        
        if (-not (Test-Path $spotifyModulePath) -or $Force) {
            New-Item -ItemType Directory -Path $spotifyModulePath -Force | Out-Null
            Write-Host "   ✅ Created module directory: $spotifyModulePath" -ForegroundColor Green
        }
        
        # Install module
        Write-Host "[5/6] 🔧 Installing Spotify CLI module..." -ForegroundColor Yellow
        
        # Check if source module exists
        $sourceModulePath = Join-Path $PSScriptRoot "SpotifyModule.psm1"
        if (-not (Test-Path $sourceModulePath)) {
            throw "Source module file not found: $sourceModulePath"
        }
        
        # Copy module
        $targetModulePath = Join-Path $spotifyModulePath "SpotifyCommands.psm1"
        Copy-Item $sourceModulePath -Destination $targetModulePath -Force
        Write-Host "   ✅ Module copied to PowerShell modules directory" -ForegroundColor Green
        
        # Create module manifest
        $manifestPath = Join-Path $spotifyModulePath "SpotifyCommands.psd1"
        $manifestContent = @"
@{
    RootModule = 'SpotifyCommands.psm1'
    ModuleVersion = '2.0.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Spotify CLI Enhanced'
    Description = 'Enhanced Spotify CLI with advanced features and cross-platform compatibility'
    PowerShellVersion = '5.0'
}
"@
        $manifestContent | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Host "   ✅ Module manifest created" -ForegroundColor Green
        
        # Configure PowerShell profile
        Write-Host "[6/6] 📋 Configuring PowerShell profile..." -ForegroundColor Yellow
        
        $profilePath = $PROFILE.CurrentUserAllHosts
        $profileDir = Split-Path $profilePath -Parent
        
        # Create profile directory if needed
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            Write-Host "   ✅ Created profile directory" -ForegroundColor Green
        }
        
        # Add import statement to profile
        $profileContent = ""
        if (Test-Path $profilePath) {
            $profileContent = Get-Content $profilePath -Raw
        }
        
        if ($profileContent -notmatch "Import-Module SpotifyCommands") {
            $profileAddition = @"

# Spotify CLI Enhanced Edition - Auto-generated
if (Get-Module -ListAvailable -Name SpotifyCommands) {
    Import-Module SpotifyCommands -DisableNameChecking -Force
}
"@
            Add-Content -Path $profilePath -Value $profileAddition -Encoding UTF8
            Write-Host "   ✅ Added Spotify CLI import to PowerShell profile" -ForegroundColor Green
        } else {
            Write-Host "   ✅ Spotify CLI already configured in profile" -ForegroundColor Green
        }
        
        # Test installation
        Write-Host ""
        Write-Host "🧪 Testing installation..." -ForegroundColor Yellow
        $testResult = pwsh -NoProfile -Command "Import-Module SpotifyCommands; Get-Command -Module SpotifyCommands | Where-Object Name -eq 'playlists'"
        
        if ($testResult) {
            Write-Host "✅ Installation test passed!" -ForegroundColor Green
        } else {
            Write-Host "❌ Installation test failed" -ForegroundColor Red
            throw "Module installation verification failed"
        }
        
        # Check environment variables
        Write-Host ""
        Write-Host "🔍 Checking Spotify API credentials..." -ForegroundColor Yellow
        $hasClientId = [System.Environment]::GetEnvironmentVariable("SPOTIFY_CLIENT_ID", "User") -or 
                      [System.Environment]::GetEnvironmentVariable("SPOTIFY_CLIENT_ID", "Process")
        $hasClientSecret = [System.Environment]::GetEnvironmentVariable("SPOTIFY_CLIENT_SECRET", "User") -or 
                          [System.Environment]::GetEnvironmentVariable("SPOTIFY_CLIENT_SECRET", "Process")
        
        if ($hasClientId -and $hasClientSecret) {
            Write-Host "✅ Spotify API credentials configured" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Spotify API credentials not found" -ForegroundColor Yellow
            Write-Host "💡 You'll need to configure SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET" -ForegroundColor Cyan
            Write-Host "💡 Check the .env.example file for instructions" -ForegroundColor Cyan
        }
        
        # Success summary
        Write-Host ""
        Write-Host "🎉 Installation completed successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "✅ Components installed:" -ForegroundColor Green
        Write-Host "   • PowerShell module installed and configured" -ForegroundColor White
        Write-Host "   • PowerShell profile updated" -ForegroundColor White
        Write-Host "   • App data directory created" -ForegroundColor White
        Write-Host "   • Optional modules installed" -ForegroundColor White
        
        Write-Host ""
        Write-Host "💡 Next steps:" -ForegroundColor Cyan
        Write-Host "   1. Restart PowerShell or run: . `$PROFILE" -ForegroundColor White
        Write-Host "   2. Configure Spotify API credentials if needed" -ForegroundColor White
        Write-Host "   3. Test with: pl (to see your playlists)" -ForegroundColor White
        Write-Host "   4. Get help with: spotify" -ForegroundColor White
        
    } catch {
        Write-Host ""
        Write-Host "❌ Installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Please check the error above and try again" -ForegroundColor Yellow
        throw
    }
}

# Run installation if script is executed directly
if ($MyInvocation.InvocationName -ne '.') {
    Install-SpotifyCLI @args
}