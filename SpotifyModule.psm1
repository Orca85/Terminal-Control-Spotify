# Spotify PowerShell Module - Fixed Version
# Simple, working version with core functionality
# Configuration Section
$script:ClientId = $env:SPOTIFY_CLIENT_ID
$script:ClientSecret = $env:SPOTIFY_CLIENT_SECRET
$script:RedirectUri = "http://127.0.0.1:8888/callback"
$script:Scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-private playlist-read-private user-library-read user-library-modify user-read-recently-played user-top-read"
$script:AppDataDir = Join-Path $env:APPDATA "SpotifyCLI"
$script:TokenFile = Join-Path $script:AppDataDir "tokens.json"
$script:ConfigFile = Join-Path $script:AppDataDir "config.json"
$script:TokenEndpoint = "https://accounts.spotify.com/api/token"
$script:ApiBase = "https://api.spotify.com/v1"
# Session storage for numbered references
$script:SessionDevices = @()
$script:SessionTracks = @()
$script:SessionPlaylists = @()
$script:SessionAlbums = @()
# Default configuration
$script:DefaultConfig = @{
    PreferredDevice = $null
    CompactMode = $false
    NotificationsEnabled = $false
    AutoRefreshInterval = 0
    LoggingEnabled = $false
    HistoryEnabled = $true
    MaxHistoryEntries = 100
    LogLevel = "Info"
    MaxLogSizeMB = 10
    LogRetentionDays = 30
    Colors = @{
        Playing = "Green"
        Paused = "Yellow"
        Track = "Cyan"
        Artist = "Yellow"
        Album = "Green"
        Progress = "Magenta"
    }
    Aliases = @{
        'spotify' = 'Start-SpotifyApp'
        'plays-now' = 'Show-SpotifyTrack'
        'music' = 'Show-SpotifyTrack'
        'pn' = 'Show-SpotifyTrack'
        'sp' = 'Show-SpotifyTrack'
        'vol' = 'volume'
        'sh' = 'shuffle'
        'rep' = 'repeat'
        'tr' = 'transfer'
        'q' = 'queue'
        'pl' = 'playlists'
        'help' = 'Get-SpotifyHelp'
    }
}
# End Configuration Section
# Helper Functions Section
function Initialize-TokenStore {
    if (-not (Test-Path $script:AppDataDir)) {
        New-Item -ItemType Directory -Path $script:AppDataDir | Out-Null
    }
    if (-not (Test-Path $script:TokenFile)) {
        '{}' | Set-Content -Path $script:TokenFile -Encoding UTF8
    }
}
function Get-StoredTokens {
    Initialize-TokenStore
    try {
        $json = Get-Content -Path $script:TokenFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
        return ($json | ConvertFrom-Json)
    } catch { return @{} }
}
function Set-StoredTokens($Tokens) {
    Initialize-TokenStore
    ($Tokens | ConvertTo-Json -Depth 5) | Set-Content -Path $script:TokenFile -Encoding UTF8
}
function Get-SpotifyAccessToken {
    $tokens = Get-StoredTokens
    if (-not $tokens.access_token) {
        Write-Host "🔐 Authentication required. Please run the main CLI script first to authenticate." -ForegroundColor Yellow
        Write-Host "Run: .\spotifyCLI.ps1" -ForegroundColor Cyan
        return $null
    }
    # Check if token has required scopes for enhanced features
    if (-not (Test-TokenScopes $tokens)) {
        Write-Host "🔐 Token requires additional permissions. Please re-authenticate using the main CLI script." -ForegroundColor Yellow
        Write-Host "Run: .\spotifyCLI.ps1" -ForegroundColor Cyan
        return $null
    }
    # Check if token is expired and refresh if needed
    $obtained = [long]$tokens.obtained_at
    $expiresIn = [int]$tokens.expires_in
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $obtained
    if ($age -ge ($expiresIn - 60)) {
        # Token is expired, try to refresh
        if (-not $tokens.refresh_token) {
            Write-Host "🔐 Token expired and no refresh token available. Please re-authenticate." -ForegroundColor Yellow
            Write-Host "Run: .\spotifyCLI.ps1" -ForegroundColor Cyan
            return $null
        }
        try {
            $body = @{
                grant_type = "refresh_token"
                refresh_token = $tokens.refresh_token
                client_id = $env:SPOTIFY_CLIENT_ID
                client_secret = $env:SPOTIFY_CLIENT_SECRET
            }
            $tokenResp = Invoke-RestMethod -Method Post -Uri "https://accounts.spotify.com/api/token" -Body $body
            $tokens.access_token = $tokenResp.access_token
            if ($tokenResp.refresh_token) { $tokens.refresh_token = $tokenResp.refresh_token }
            $tokens.expires_in = $tokenResp.expires_in
            $tokens.obtained_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Set-StoredTokens $tokens
            Write-Host "🔄 Token refreshed successfully" -ForegroundColor Green
        } catch {
            Write-Host "🔄 Token refresh failed. Please re-authenticate." -ForegroundColor Red
            Write-Host "Run: .\spotifyCLI.ps1" -ForegroundColor Cyan
            return $null
        }
    }
    return $tokens.access_token
}
function Test-TokenScopes {
    <#
    .SYNOPSIS
    Test if current token has required scopes for enhanced features
    #>
    param($Tokens)
    # If no scope information is stored, assume old token and require re-auth
    if (-not $Tokens.scopes) {
        return $false
    }
    # Check if all required scopes are present
    $requiredScopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-private playlist-read-private user-library-read user-library-modify user-read-recently-played user-top-read" -split ' '
    $tokenScopes = $Tokens.scopes -split ' '
    foreach ($scope in $requiredScopes) {
        if ($scope -notin $tokenScopes) {
            Write-Verbose "Missing required scope: $scope"
            return $false
        }
    }
    return $true
}
function Invoke-SpotifyApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        $Body
    )
    $access = Get-SpotifyAccessToken
    if (-not $access) { return $null }
    # Build the complete URI
    $uri = "https://api.spotify.com/v1$Path"
    if ($Query -and $Query.Count -gt 0) {
        $queryString = ($Query.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))"
        }) -join "&"
        $uri += "?$queryString"
    }
    $headers = @{ Authorization = "Bearer $access" }
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 10)
        } else {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        switch ($statusCode) {
            401 {
                Write-Host "🔐 Authentication Error: Your Spotify session has expired." -ForegroundColor Red
                Write-Host "💡 Solution: Run .\spotifyCLI.ps1 to re-authenticate" -ForegroundColor Yellow
            }
            403 {
                Write-Host "🚫 Permission Error: This operation requires Spotify Premium." -ForegroundColor Red
            }
            404 {
                if ($Path -like "*device*") {
                    Write-Host "📱 No Active Device: Please start Spotify on any device first." -ForegroundColor Red
                } elseif ($Path -like "*player*") {
                    Write-Host "🎵 No Active Playback: No music is currently playing or paused." -ForegroundColor Red
                    Write-Host "💡 Start playing music on Spotify first, then try this command." -ForegroundColor Yellow
                } else {
                    Write-Host "❓ Not Found: The requested resource was not found." -ForegroundColor Red
                }
            }
            429 {
                Write-Host "⏳ Rate Limit: Too many requests. Please wait a moment." -ForegroundColor Yellow
            }
            default {
                Write-Host "❌ API Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        return $null
    }
}
function Get-SpotifyConfig {
    if (-not (Test-Path $script:ConfigFile)) {
        return $script:DefaultConfig.Clone()
    }
    try {
        $json = Get-Content -Path $script:ConfigFile -Raw -ErrorAction Stop
        $config = ($json | ConvertFrom-Json)
        $result = $script:DefaultConfig.Clone()
        $config.PSObject.Properties | ForEach-Object {
            if ($_.Name -eq "Colors" -and $_.Value) {
                $result.Colors = @{}
                $_.Value.PSObject.Properties | ForEach-Object {
                    $result.Colors[$_.Name] = $_.Value
                }
            } elseif ($_.Name -eq "Aliases" -and $_.Value) {
                $result.Aliases = @{}
                $_.Value.PSObject.Properties | ForEach-Object {
                    $result.Aliases[$_.Name] = $_.Value
                }
            } else {
                $result[$_.Name] = $_.Value
            }
        }
        return $result
    } catch {
        return $script:DefaultConfig.Clone()
    }
}
function Set-SpotifyConfig {
    param([hashtable]$Config)
    try {
        if (-not (Test-Path $script:AppDataDir)) {
            New-Item -ItemType Directory -Path $script:AppDataDir | Out-Null
        }
        ($Config | ConvertTo-Json -Depth 5) | Set-Content -Path $script:ConfigFile -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}
function Format-Time {
    param([int]$ms)
    $totalSec = [int][Math]::Round($ms / 1000.0)
    $m = [Math]::Floor($totalSec / 60)
    $s = $totalSec % 60
    "{0}:{1:D2}" -f $m, $s
}
function Show-ProgressBar {
    param([int]$Current, [int]$Total, [int]$Width = 30)
    if ($Total -le 0) { return "[$("░" * $Width)] 0%" }
    $percentage = [Math]::Round(($Current / $Total) * 100)
    $filled = [Math]::Round(($Current / $Total) * $Width)
    $empty = $Width - $filled
    if ($filled -gt $Width) { $filled = $Width; $empty = 0 }
    if ($filled -lt 0) { $filled = 0; $empty = $Width }
    $bar = "█" * $filled + "░" * $empty
    return "[$bar] $percentage%"
}
function Get-StatusColor {
    param([bool]$IsPlaying)
    $config = Get-SpotifyConfig
    if ($IsPlaying) {
        return $config.Colors.Playing
    } else {
        return $config.Colors.Paused
    }
}
function Get-TrackColor {
    $config = Get-SpotifyConfig
    return $config.Colors.Track
}
function Get-ArtistColor {
    $config = Get-SpotifyConfig
    return $config.Colors.Artist
}
function Get-AlbumColor {
    $config = Get-SpotifyConfig
    return $config.Colors.Album
}
function Get-ProgressColor {
    $config = Get-SpotifyConfig
    return $config.Colors.Progress
}
# End Helper Functions Section
# Core Commands Section
function Start-SpotifyApp {
    <#
    .SYNOPSIS
    Launch the Spotify desktop application
    .DESCRIPTION
    Launches the Spotify desktop application using multiple detection methods.
    Supports both desktop app and web player launching with comprehensive error handling.
    .PARAMETER Web
    Open Spotify Web Player instead of desktop app
    .PARAMETER WaitForReady
    Wait for Spotify to become available after launching
    .PARAMETER Force
    Force launch even if Spotify is already running (opens new instance)
    .EXAMPLE
    Start-SpotifyApp
    Launches the Spotify desktop application
    .EXAMPLE
    Start-SpotifyApp -Web
    Opens Spotify Web Player in default browser
    .EXAMPLE
    Start-SpotifyApp -WaitForReady
    Launches Spotify and waits for it to become ready
    #>
    param(
        [switch]$Web,
        [switch]$WaitForReady,
        [switch]$Force
    )
    if ($Web) {
        Write-Host "🌐 Opening Spotify Web Player..." -ForegroundColor Cyan
        try {
            Start-Process "https://open.spotify.com" -ErrorAction Stop
            Write-Host "✅ Web player opened successfully" -ForegroundColor Green
            Write-Host "💡 Sign in to your Spotify account to start using the web player" -ForegroundColor Cyan
        } catch {
            Write-Host "❌ Failed to open web player: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Write-Host "🔧 TROUBLESHOOTING:" -ForegroundColor Yellow
            Write-Host "• Try opening https://open.spotify.com manually in your browser" -ForegroundColor White
            Write-Host "• Check if your default browser is set correctly" -ForegroundColor White
            Write-Host "• Ensure you have an internet connection" -ForegroundColor White
        }
        return
    }
    Write-Host "🚀 Launching Spotify application..." -ForegroundColor Cyan
    # Check if Spotify is already running
    $spotifyProcesses = Get-Process -Name "Spotify" -ErrorAction SilentlyContinue
    if ($spotifyProcesses -and -not $Force) {
        $processCount = $spotifyProcesses.Count
        $mainProcess = $spotifyProcesses | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
        if ($mainProcess) {
            Write-Host "✅ Spotify is already running and ready (PID: $($mainProcess.Id))" -ForegroundColor Green
            Write-Host "💡 Use 'Start-SpotifyApp -Force' to launch another instance" -ForegroundColor Cyan
        } else {
            Write-Host "✅ Spotify processes detected ($processCount running)" -ForegroundColor Green
            Write-Host "💡 Spotify may be starting up or running in background" -ForegroundColor Cyan
        }
        return
    }
    # Try multiple methods to launch Spotify
    $launched = $false
    $launchMethod = ""
    $launchPath = ""
    # Method 1: Try common installation paths for desktop app
    Write-Host "🔍 Checking for desktop Spotify installation..." -ForegroundColor Gray
    $spotifyPaths = @(
        @{ Path = "$env:APPDATA\Spotify\Spotify.exe"; Type = "User Installation" },
        @{ Path = "${env:ProgramFiles}\Spotify\Spotify.exe"; Type = "System Installation (64-bit)" },
        @{ Path = "${env:ProgramFiles(x86)}\Spotify\Spotify.exe"; Type = "System Installation (32-bit)" }
    )
    foreach ($pathInfo in $spotifyPaths) {
        $path = $pathInfo.Path
        $type = $pathInfo.Type
        if (Test-Path $path) {
            Write-Host "✅ Found Spotify: $type" -ForegroundColor Green
            try {
                Start-Process $path -ErrorAction Stop
                $launched = $true
                $launchMethod = "Desktop App ($type)"
                $launchPath = $path
                break
            } catch {
                Write-Host "⚠️ Failed to launch from $path : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    # Method 2: Try Windows Store version via protocol
    if (-not $launched) {
        Write-Host "🔍 Trying Windows Store version..." -ForegroundColor Gray
        try {
            # Test if protocol is available first
            $protocolTest = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("spotify")
            if ($protocolTest) {
                $protocolTest.Close()
                Start-Process "spotify:" -ErrorAction Stop
                $launched = $true
                $launchMethod = "Windows Store App (Protocol)"
                Write-Host "✅ Launched via spotify: protocol" -ForegroundColor Green
            } else {
                Write-Host "ℹ️ Spotify protocol not registered" -ForegroundColor Gray
            }
        } catch {
            Write-Host "ℹ️ Windows Store version not available: $($_.Exception.Message)" -ForegroundColor Gray
        }
    }
    # Method 3: Try using COM Shell Application
    if (-not $launched) {
        Write-Host "🔍 Trying shell execute method..." -ForegroundColor Gray
        try {
            $shell = New-Object -ComObject Shell.Application -ErrorAction Stop
            $shell.ShellExecute("spotify:")
            $launched = $true
            $launchMethod = "Shell Execute (Protocol)"
            Write-Host "✅ Launched via shell execute" -ForegroundColor Green
        } catch {
            Write-Host "ℹ️ Shell execute method failed: $($_.Exception.Message)" -ForegroundColor Gray
        }
    }
    # Method 4: Try Windows Run dialog approach
    if (-not $launched) {
        Write-Host "🔍 Trying Windows Run approach..." -ForegroundColor Gray
        try {
            $wshell = New-Object -ComObject WScript.Shell -ErrorAction Stop
            $wshell.Run("spotify:", 1, $false)
            $launched = $true
            $launchMethod = "WScript Shell (Protocol)"
            Write-Host "✅ Launched via WScript shell" -ForegroundColor Green
        } catch {
            Write-Host "ℹ️ WScript shell method failed: $($_.Exception.Message)" -ForegroundColor Gray
        }
    }
    if (-not $launched) {
        Write-Host ""
        Write-Host "❌ Spotify could not be launched" -ForegroundColor Red
        Write-Host ""
        Write-Host "🔧 INSTALLATION REQUIRED:" -ForegroundColor Yellow
        Write-Host "Spotify is not installed on this system." -ForegroundColor White
        Write-Host ""
        Write-Host "📥 INSTALLATION OPTIONS:" -ForegroundColor Cyan
        Write-Host "1. Desktop App: https://www.spotify.com/download/" -ForegroundColor White
        Write-Host "2. Microsoft Store: ms-windows-store://pdp/?productid=9NCBCSZSJRSB" -ForegroundColor White
        Write-Host "3. Web Player: Use 'spotify -Web' or visit https://open.spotify.com" -ForegroundColor White
        Write-Host ""
        Write-Host "💡 QUICK ALTERNATIVES:" -ForegroundColor Green
        Write-Host "• Run: spotify -Web    (opens web player)" -ForegroundColor White
        Write-Host "• Run: Start-SpotifyApp -Web" -ForegroundColor White
        # Try to open installation page
        $response = Read-Host "Open Spotify download page in browser? (y/N)"
        if ($response -eq 'y' -or $response -eq 'Y') {
            try {
                Start-Process "https://www.spotify.com/download/" -ErrorAction Stop
                Write-Host "✅ Download page opened in browser" -ForegroundColor Green
            } catch {
                Write-Host "❌ Could not open browser. Please visit: https://www.spotify.com/download/" -ForegroundColor Red
            }
        }
        return
    }
    Write-Host "✅ Spotify launched successfully using: $launchMethod" -ForegroundColor Green
    if ($launchPath) {
        Write-Host "📁 Path: $launchPath" -ForegroundColor Gray
    }
    # Wait for Spotify to become ready if requested
    if ($WaitForReady) {
        Write-Host ""
        Write-Host "⏳ Waiting for Spotify to become ready..." -ForegroundColor Yellow
        $timeout = 30 # seconds
        $elapsed = 0
        $ready = $false
        do {
            Start-Sleep -Seconds 1
            $elapsed++
            # Check for Spotify processes
            $spotifyProcess = Get-Process -Name "Spotify" -ErrorAction SilentlyContinue
            if ($spotifyProcess) {
                # Check if main window is available (indicates ready state)
                $mainWindow = $spotifyProcess | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
                if ($mainWindow) {
                    $ready = $true
                    Write-Host "✅ Spotify is now active and ready (PID: $($mainWindow.Id))" -ForegroundColor Green
                    Write-Host "🎵 Window Title: $($mainWindow.MainWindowTitle)" -ForegroundColor Gray
                    break
                }
            }
            # Show progress every 5 seconds
            if ($elapsed % 5 -eq 0) {
                Write-Host "⏳ Still waiting... ($elapsed/$timeout seconds)" -ForegroundColor Yellow
            }
        } while ($elapsed -lt $timeout)
        if (-not $ready) {
            Write-Host "⚠️ Spotify launch timeout after $timeout seconds" -ForegroundColor Yellow
            Write-Host "💡 Spotify may still be starting up in the background" -ForegroundColor Cyan
            # Final check for any Spotify processes
            $anySpotifyProcess = Get-Process -Name "Spotify" -ErrorAction SilentlyContinue
            if ($anySpotifyProcess) {
                Write-Host "ℹ️ Spotify processes detected: $($anySpotifyProcess.Count)" -ForegroundColor Cyan
            }
        }
    } else {
        Write-Host "💡 Use 'Start-SpotifyApp -WaitForReady' to wait for Spotify to fully load" -ForegroundColor Cyan
    }
}
function Show-SpotifyTrack {
    param([string]$Mode)
    try {
        $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
        if (-not $currentTrack -or -not $currentTrack.item) {
            Write-Host "No track currently playing" -ForegroundColor Yellow
            return
        }
        $config = Get-SpotifyConfig
        $isCompact = ($Mode -eq "compact") -or $config.CompactMode
        $item = $currentTrack.item
        $isPlaying = $currentTrack.is_playing
        $progress = $currentTrack.progress_ms
        $duration = $item.duration_ms
        # Detect if this is a podcast episode
        $isPodcast = $item.type -eq "episode" -or ($currentTrack.currently_playing_type -eq "episode")
        if ($isCompact) {
            $playIcon = if ($isPlaying) { "▶️" } else { "⏸️" }
            $name = if ($item.name.Length -gt 25) { $item.name.Substring(0, 22) + "..." } else { $item.name }
            if ($isPodcast) {
                # Podcast episode compact display
                $showName = if ($item.show.name.Length -gt 20) { $item.show.name.Substring(0, 17) + "..." } else { $item.show.name }
                $progressBar = Show-ProgressBar -Current $progress -Total $duration -Width 15
                $timeInfo = "{0}/{1}" -f (Format-Time $progress), (Format-Time $duration)
                Write-Host "$playIcon $name" -ForegroundColor Cyan
                Write-Host "    🎙️ $showName | $progressBar $timeInfo" -ForegroundColor Magenta
            } else {
                # Music track compact display
                $artists = ($item.artists | ForEach-Object { $_.name }) -join ", "
                if ($artists.Length -gt 20) { $artists = $artists.Substring(0, 17) + "..." }
                $progressBar = Show-ProgressBar -Current $progress -Total $duration -Width 15
                $timeInfo = "{0}/{1}" -f (Format-Time $progress), (Format-Time $duration)
                Write-Host "$playIcon $name - $artists | $progressBar $timeInfo" -ForegroundColor Cyan
            }
        } else {
            if ($isPodcast) {
                # Enhanced detailed mode for podcast episodes
                Write-Host "🎙️ " -NoNewline -ForegroundColor Magenta
                Write-Host $item.name -ForegroundColor Cyan
                Write-Host "📻 " -NoNewline -ForegroundColor Yellow
                Write-Host $item.show.name -ForegroundColor Yellow
                # Show podcast description if available (truncated for readability)
                if ($item.description) {
                    $description = $item.description
                    if ($description.Length -gt 100) {
                        $description = $description.Substring(0, 97) + "..."
                    }
                    Write-Host "📝 " -NoNewline -ForegroundColor Gray
                    Write-Host $description -ForegroundColor Gray
                }
                # Show episode release date if available
                if ($item.release_date) {
                    try {
                        $releaseDate = [DateTime]::Parse($item.release_date)
                        Write-Host "📅 Released: $($releaseDate.ToString('MMM dd, yyyy'))" -ForegroundColor Gray
                    } catch {
                        Write-Host "📅 Released: $($item.release_date)" -ForegroundColor Gray
                    }
                }
                # Show episode language if available
                if ($item.language) {
                    Write-Host "🌐 Language: $($item.language.ToUpper())" -ForegroundColor Gray
                }
                # Show if episode is explicit
                if ($item.explicit) {
                    Write-Host "🔞 Explicit Content" -ForegroundColor Red
                }
                Write-Host ""  # New line after episode info
                # Progress bar for podcast episodes
                $progressBar = Show-ProgressBar -Current $progress -Total $duration
                Write-Host $progressBar -ForegroundColor Magenta
                $timeInfo = "{0} / {1}" -f (Format-Time $progress), (Format-Time $duration)
                $statusIcon = if ($isPlaying) { "▶️ Playing" } else { "⏸️ Paused" }
                Write-Host "⏱ $timeInfo $statusIcon" -ForegroundColor Gray
                # Show podcast show context
                Write-Host "💡 Podcast episode from '$($item.show.name)'" -ForegroundColor Cyan
            } else {
                # Music track detailed display
                Write-Host "🎵 " -NoNewline -ForegroundColor Cyan
                Write-Host $item.name -ForegroundColor Cyan
                Write-Host "👤 " -NoNewline -ForegroundColor Yellow
                Write-Host (($item.artists | ForEach-Object { $_.name }) -join ", ") -ForegroundColor Yellow
                Write-Host "📀 " -NoNewline -ForegroundColor Green
                Write-Host $item.album.name -ForegroundColor Green
                $progressBar = Show-ProgressBar -Current $progress -Total $duration
                Write-Host $progressBar -ForegroundColor Magenta
                $timeInfo = "{0} / {1}" -f (Format-Time $progress), (Format-Time $duration)
                $statusIcon = if ($isPlaying) { "▶️ Playing" } else { "⏸️ Paused" }
                Write-Host "⏱ $timeInfo $statusIcon" -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "Error getting current track: $($_.Exception.Message)" -ForegroundColor Red
    }
}
# Create alias for backward compatibility and easier typing
function spotify-now {
    param([string]$Mode)
    Show-SpotifyTrack $Mode
}
function play {
    param([string]$TrackReference)
    # If no parameter, try to resume playback or start from recent tracks
    if ([string]::IsNullOrWhiteSpace($TrackReference)) {
        $result = Invoke-SpotifyApi -Method PUT -Path "/me/player/play"
        if ($result -ne $null) {
            Write-Host "▶️ Resumed playback" -ForegroundColor Green
        } else {
            # Check if we have available devices
            $devicesResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/devices"
            if ($devicesResponse -and $devicesResponse.devices -and $devicesResponse.devices.Count -gt 0) {
                # We have devices, try to start playing the most recent track
                Write-Host "🎵 No active playback found. Trying to start from your recent tracks..." -ForegroundColor Yellow
                try {
                    # First, try to activate the device by transferring playback to it
                    $activeDevice = $devicesResponse.devices | Where-Object { $_.is_active -eq $true } | Select-Object -First 1
                    if (-not $activeDevice) {
                        # No active device, try to activate the first available one
                        $firstDevice = $devicesResponse.devices[0]
                        Write-Host "🔄 Activating device: $($firstDevice.name)..." -ForegroundColor Cyan
                        $transferBody = @{ device_ids = @($firstDevice.id); play = $false }
                        Invoke-SpotifyApi -Method PUT -Path "/me/player" -Body $transferBody | Out-Null
                        Start-Sleep -Milliseconds 500  # Give it a moment to activate
                    }
                    # Now try to get recent tracks and start playing
                    $recentTracks = Invoke-SpotifyApi -Method GET -Path "/me/player/recently-played" -Query @{ limit = 1 }
                    if ($recentTracks -and $recentTracks.items -and $recentTracks.items.Count -gt 0) {
                        $lastTrack = $recentTracks.items[0].track
                        $body = @{ uris = @($lastTrack.uri) }
                        $playResult = Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body
                        if ($playResult -ne $null) {
                            Write-Host "▶️ Started playing: $($lastTrack.name) by $($lastTrack.artists[0].name)" -ForegroundColor Green
                        } else {
                            Write-Host "❌ Could not start playback automatically." -ForegroundColor Red
                            Write-Host "💡 Try: Open Spotify, manually play any song, then use CLI commands." -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "❌ No recent tracks found." -ForegroundColor Red
                        Write-Host "💡 Try: Open Spotify, manually play any song, then use CLI commands." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "❌ Could not start playback automatically." -ForegroundColor Red
                    Write-Host "💡 Try: Open Spotify, manually play any song, then use CLI commands." -ForegroundColor Yellow
                }
            } else {
                Write-Host "❌ Could not resume playback. Make sure Spotify is open and you have an active device." -ForegroundColor Red
                Write-Host "💡 Try: Start Spotify on your phone/computer, play a song, then try again." -ForegroundColor Yellow
            }
        }
        return
    }
    $trackUri = $TrackReference
    # Check if it's a number (track/episode index from search)
    if ($TrackReference -match '^\d+$') {
        $itemIndex = [int]$TrackReference - 1
        if ($script:SessionTracks -and $itemIndex -ge 0 -and $itemIndex -lt $script:SessionTracks.Count) {
            $item = $script:SessionTracks[$itemIndex]
            $trackUri = $item.uri
            $itemName = $item.name
            if ($item.search_type -eq "episode" -or $item.type -eq "episode") {
                # Playing podcast episode
                $showName = $item.show.name
                Write-Host "🎯 Playing podcast episode #$TrackReference ($itemName from $showName)..." -ForegroundColor Magenta
            } else {
                # Playing music track
                $artists = ($item.artists | ForEach-Object { $_.name }) -join ", "
                Write-Host "🎯 Playing track #$TrackReference ($itemName by $artists)..." -ForegroundColor Cyan
            }
        } else {
            Write-Host "❌ Invalid item number. Use 'search' to find tracks and episodes first." -ForegroundColor Red
            return
        }
    }
    # Ensure it's a valid Spotify URI
    if (-not ($trackUri.StartsWith("spotify:track:") -or $trackUri.StartsWith("spotify:episode:"))) {
        Write-Host "❌ Invalid URI. Must be a Spotify track or episode URI" -ForegroundColor Red
        return
    }
    try {
        $body = @{ uris = @($trackUri) }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
        if ($trackUri.StartsWith("spotify:episode:")) {
            Write-Host "▶️ Playing podcast episode" -ForegroundColor Magenta
        } else {
            Write-Host "▶️ Playing track" -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ Could not play track" -ForegroundColor Red
    }
}
function pause {
    $result = Invoke-SpotifyApi -Method PUT -Path "/me/player/pause"
    if ($result -ne $null) {
        Write-Host "⏸️ Paused playback" -ForegroundColor Yellow
    } else {
        Write-Host "❌ Could not pause playback. Make sure Spotify is open and playing." -ForegroundColor Red
        Write-Host "💡 Try: Start Spotify on your phone/computer and play a song first." -ForegroundColor Yellow
    }
}
function next {
    $result = Invoke-SpotifyApi -Method POST -Path "/me/player/next"
    if ($result -ne $null) {
        Write-Host "⏭️ Skipped to next track" -ForegroundColor Green
        # Wait a moment for Spotify to update, then show notification
        Start-Sleep -Milliseconds 500
        # Get current track info and show notification
        try {
            $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
            if ($currentTrack -and $currentTrack.item) {
                Show-TrackNotification -TrackInfo $currentTrack.item
            }
        } catch {
            # If we can't get track info, show generic notification
            Show-TrackNotification -Title "Spotify" -Message "Skipped to next track"
        }
    } else {
        Write-Host "❌ Could not skip to next track. Make sure Spotify is playing music." -ForegroundColor Red
        Write-Host "💡 Try: Start playing music on Spotify first." -ForegroundColor Yellow
    }
}
function previous {
    $result = Invoke-SpotifyApi -Method POST -Path "/me/player/previous"
    if ($result -ne $null) {
        Write-Host "⏮️ Skipped to previous track" -ForegroundColor Green
        # Wait a moment for Spotify to update, then show notification
        Start-Sleep -Milliseconds 500
        # Get current track info and show notification
        try {
            $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
            if ($currentTrack -and $currentTrack.item) {
                Show-TrackNotification -TrackInfo $currentTrack.item
            }
        } catch {
            # If we can't get track info, show generic notification
            Show-TrackNotification -Title "Spotify" -Message "Skipped to previous track"
        }
    } else {
        Write-Host "❌ Could not skip to previous track. Make sure Spotify is playing music." -ForegroundColor Red
        Write-Host "💡 Try: Start playing music on Spotify first." -ForegroundColor Yellow
    }
}
function devices {
    try {
        $devicesResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/devices"
        if (-not $devicesResponse -or -not $devicesResponse.devices -or $devicesResponse.devices.Count -eq 0) {
            Write-Host "📱 No Spotify Connect devices found" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "💡 To use device management features:" -ForegroundColor Cyan
            Write-Host "1. Open Spotify on any device (phone, computer, speaker, etc.)" -ForegroundColor White
            Write-Host "2. Start playing any song to activate the device" -ForegroundColor White
            Write-Host "3. Run 'devices' again to see available devices" -ForegroundColor White
            Write-Host ""
            Write-Host "🎵 Supported device types: Computer, Phone, Speaker, TV, Tablet" -ForegroundColor Gray
            return
        }
        # Store devices in session for numbered reference
        $script:SessionDevices = $devicesResponse.devices
        Write-Host "📱 Available Devices:" -ForegroundColor Cyan
        $i = 1
        foreach ($device in $devicesResponse.devices) {
            $deviceIcon = switch ($device.type.ToLower()) {
                "computer" { "💻" }
                "smartphone" { "📱" }
                "speaker" { "🔊" }
                "tv" { "📺" }
                default { "🎵" }
            }
            $activeStatus = if ($device.is_active) { "Active" } else { "Inactive" }
            $volumeInfo = if ($device.volume_percent -ne $null) { ", Volume: $($device.volume_percent)%" } else { "" }
            Write-Host "$i. $deviceIcon $($device.name) ($($device.type)) - $activeStatus$volumeInfo" -ForegroundColor White
            $i++
        }
        Write-Host ""
        Write-Host "💡 Tip: Use 'transfer 1' to switch to device #1" -ForegroundColor Gray
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        switch ($statusCode) {
            401 {
                Write-Host "🔐 Authentication Error: Your Spotify session has expired." -ForegroundColor Red
                Write-Host "💡 The CLI will automatically re-authenticate you." -ForegroundColor Yellow
            }
            403 {
                Write-Host "🚫 Permission Error: Device management requires Spotify Premium." -ForegroundColor Red
                Write-Host "💡 Available with Free account: View current track, search music" -ForegroundColor Yellow
            }
            default {
                Write-Host "❌ Could not get devices: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "💡 Check your internet connection and try again" -ForegroundColor Yellow
            }
        }
    }
}
function search {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-Host "Usage: search '<query>'" -ForegroundColor Yellow
        return
    }
    try {
        $searchQuery = @{
            q = $Query
            type = "track,artist,album,episode"
            limit = "10"
        }
        Write-Host "Searching for: $Query" -ForegroundColor Gray
        $results = Invoke-SpotifyApi -Method GET -Path "/search" -Query $searchQuery
        if (-not $results) { return }
        Write-Host "🔍 Search Results for '$Query':" -ForegroundColor Cyan
        Write-Host ""
        # Combine tracks and episodes for numbered reference
        $allItems = @()
        $trackCount = 0
        $episodeCount = 0
        if ($results.tracks -and $results.tracks.items) {
            $trackCount = $results.tracks.items.Count
            $allItems += $results.tracks.items[0..4] | ForEach-Object {
                $_ | Add-Member -NotePropertyName "search_type" -NotePropertyValue "track" -PassThru
            }
        }
        if ($results.episodes -and $results.episodes.items) {
            $episodeCount = $results.episodes.items.Count
            $allItems += $results.episodes.items[0..4] | ForEach-Object {
                $_ | Add-Member -NotePropertyName "search_type" -NotePropertyValue "episode" -PassThru
            }
        }
        # Store combined items in session for numbered reference
        $script:SessionTracks = $allItems[0..9]  # Store up to 10 items (tracks + episodes)
        if ($results.tracks -and $results.tracks.items) {
            Write-Host "TRACKS:" -ForegroundColor Yellow
            $i = 1
            foreach ($track in $results.tracks.items[0..4]) {
                $artists = ($track.artists | ForEach-Object { $_.name }) -join ", "
                Write-Host "$i. $($track.name) - $artists ($($track.album.name))" -ForegroundColor White
                $i++
            }
            Write-Host ""
        }
        if ($results.episodes -and $results.episodes.items) {
            Write-Host "PODCAST EPISODES:" -ForegroundColor Magenta
            $startIndex = ($results.tracks.items.Count -gt 0) ? ($results.tracks.items[0..4].Count + 1) : 1
            $i = $startIndex
            foreach ($episode in $results.episodes.items[0..4]) {
                $showName = $episode.show.name
                $description = if ($episode.description -and $episode.description.Length -gt 50) {
                    $episode.description.Substring(0, 47) + "..."
                } else {
                    $episode.description
                }
                Write-Host "$i. 🎙️ $($episode.name) - $showName" -ForegroundColor White
                if ($description) {
                    Write-Host "   📝 $description" -ForegroundColor Gray
                }
                $i++
            }
            Write-Host ""
        }
        if ($allItems.Count -gt 0) {
            Write-Host "💡 Tip: Use 'play 1' to play item #1, or 'queue 2' to add item #2 to queue" -ForegroundColor Gray
            if ($episodeCount -gt 0) {
                Write-Host "💡 Podcast episodes can be saved using 'save-track <number>'" -ForegroundColor Gray
            }
            Write-Host "🎮 Press Enter for interactive navigation mode..." -ForegroundColor Cyan
            # Check if user wants to enter interactive mode
            $capabilities = Get-TerminalCapabilities
            if ($capabilities.SupportsInteractiveInput) {
                try {
                    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                    if ($key.VirtualKeyCode -eq 13) { # Enter key
                        Start-InteractiveMode -Items $allItems -Title "Search Results for '$Query'"
                    }
                } catch {
                    # If ReadKey fails, just continue without interactive mode
                    Write-Host "ℹ️ Interactive mode not available in this terminal" -ForegroundColor Yellow
                }
            } else {
                Write-Host "ℹ️ Interactive mode not supported in this terminal" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "❌ Search failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function search-albums {
    <#
    .SYNOPSIS
    Search for albums only on Spotify
    .DESCRIPTION
    Searches Spotify for albums matching the query and displays results with smart numbering.
    Results are stored in session for use with play-album and queue-album commands.
    .PARAMETER Query
    The search query for albums
    .EXAMPLE
    search-albums "pink floyd"
    Search for Pink Floyd albums
    .EXAMPLE
    search-albums "the beatles"
    Search for Beatles albums
    #>
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-Host "Usage: search-albums '<query>'" -ForegroundColor Yellow
        Write-Host "Example: search-albums 'pink floyd'" -ForegroundColor Gray
        return
    }
    try {
        $searchQuery = @{
            q = $Query
            type = "album"
            limit = "10"
        }
        Write-Host "🔍 Searching albums for: $Query" -ForegroundColor Gray
        $results = Invoke-SpotifyApi -Method GET -Path "/search" -Query $searchQuery
        if (-not $results -or -not $results.albums -or -not $results.albums.items -or $results.albums.items.Count -eq 0) {
            Write-Host "💿 No albums found for '$Query'" -ForegroundColor Yellow
            Write-Host "💡 Try a different search term or check spelling" -ForegroundColor Gray
            return
        }
        Write-Host "💿 Album Search Results for '$Query':" -ForegroundColor Cyan
        Write-Host ""
        # Store albums in session for numbered reference
        $script:SessionAlbums = $results.albums.items[0..9]  # Store up to 10 albums
        $i = 1
        foreach ($album in $results.albums.items[0..9]) {
            if (-not $album) { break }
            $artists = ($album.artists | ForEach-Object { $_.name }) -join ", "
            $releaseYear = if ($album.release_date) {
                try {
                    [DateTime]::Parse($album.release_date).Year
                } catch {
                    $album.release_date.Split('-')[0]
                }
            } else {
                "Unknown"
            }
            Write-Host "$i. " -NoNewline -ForegroundColor White
            Write-Host "$($album.name)" -NoNewline -ForegroundColor Cyan
            Write-Host " - " -NoNewline -ForegroundColor Gray
            Write-Host "$artists" -NoNewline -ForegroundColor Yellow
            Write-Host " ($releaseYear)" -ForegroundColor Green
            Write-Host "   💿 $($album.total_tracks) tracks" -ForegroundColor Gray
            $i++
        }
        Write-Host ""
        Write-Host "💡 Tip: Use 'play-album 1' to play album #1, or 'queue-album 2' to add album #2 to queue" -ForegroundColor Gray
    } catch {
        Write-Host "❌ Album search failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Check your internet connection and Spotify authentication" -ForegroundColor Yellow
    }
}
function play-album {
    <#
    .SYNOPSIS
    Play an album by number from the album search results
    .DESCRIPTION
    Plays an album by its number from the most recent search-albums results.
    The album will be played from the beginning.
    .PARAMETER AlbumNumber
    The number of the album from the search-albums command (1-10)
    .EXAMPLE
    play-album 1
    Play the first album from the search results
    .EXAMPLE
    search-albums "pink floyd"; play-album 2
    Search for Pink Floyd albums and play the second result
    #>
    param([Parameter(Mandatory)][int]$AlbumNumber)
    try {
        # Check if we have session albums
        if (-not $script:SessionAlbums -or $script:SessionAlbums.Count -eq 0) {
            Write-Host "❌ No albums in session. Run 'search-albums' first." -ForegroundColor Red
            Write-Host "💡 Example: search-albums 'pink floyd'" -ForegroundColor Yellow
            return
        }
        # Validate album number
        if ($AlbumNumber -lt 1 -or $AlbumNumber -gt $script:SessionAlbums.Count) {
            Write-Host "❌ Invalid album number. Use 1-$($script:SessionAlbums.Count)" -ForegroundColor Red
            Write-Host "💡 Use 'search-albums' to see available albums" -ForegroundColor Yellow
            return
        }
        $album = $script:SessionAlbums[$AlbumNumber - 1]
        $albumName = $album.name
        $albumUri = $album.uri
        $artists = ($album.artists | ForEach-Object { $_.name }) -join ", "
        Write-Host "🎵 Playing album #${AlbumNumber}: '$albumName' by $artists..." -ForegroundColor Cyan
        # Play the album using its context URI
        $body = @{ context_uri = $albumUri }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
        Write-Host "▶️ Now playing: '$albumName'" -ForegroundColor Green
        Write-Host "👤 Artist: $artists" -ForegroundColor Yellow
        Write-Host "💿 $($album.total_tracks) tracks" -ForegroundColor Gray
        # Show release info if available
        if ($album.release_date) {
            try {
                $releaseYear = [DateTime]::Parse($album.release_date).Year
                Write-Host "📅 Released: $releaseYear" -ForegroundColor Gray
            } catch {
                Write-Host "📅 Released: $($album.release_date)" -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "❌ Could not play album: $($_.Exception.Message)" -ForegroundColor Red
        # Provide helpful error context
        if ($_.Exception.Message -like "*403*") {
            Write-Host "💡 This feature requires Spotify Premium" -ForegroundColor Yellow
        } elseif ($_.Exception.Message -like "*404*") {
            Write-Host "💡 Make sure Spotify is running on an active device" -ForegroundColor Yellow
            Write-Host "💡 Try running 'devices' to see available devices" -ForegroundColor Yellow
        }
    }
}
function queue-album {
    <#
    .SYNOPSIS
    Add an entire album to the queue by number from album search results
    .DESCRIPTION
    Adds all tracks from an album to the current playback queue.
    The album is identified by its number from the most recent search-albums results.
    .PARAMETER AlbumNumber
    The number of the album from the search-albums command (1-10)
    .EXAMPLE
    queue-album 1
    Add all tracks from album #1 to the queue
    .EXAMPLE
    search-albums "radiohead"; queue-album 3
    Search for Radiohead albums and add the third result to queue
    #>
    param([Parameter(Mandatory)][int]$AlbumNumber)
    try {
        # Check if we have session albums
        if (-not $script:SessionAlbums -or $script:SessionAlbums.Count -eq 0) {
            Write-Host "❌ No albums in session. Run 'search-albums' first." -ForegroundColor Red
            Write-Host "💡 Example: search-albums 'radiohead'" -ForegroundColor Yellow
            return
        }
        # Validate album number
        if ($AlbumNumber -lt 1 -or $AlbumNumber -gt $script:SessionAlbums.Count) {
            Write-Host "❌ Invalid album number. Use 1-$($script:SessionAlbums.Count)" -ForegroundColor Red
            Write-Host "💡 Use 'search-albums' to see available albums" -ForegroundColor Yellow
            return
        }
        $album = $script:SessionAlbums[$AlbumNumber - 1]
        $albumName = $album.name
        $albumId = $album.id
        $artists = ($album.artists | ForEach-Object { $_.name }) -join ", "
        Write-Host "🎵 Adding album '$albumName' by $artists to queue..." -ForegroundColor Cyan
        # Get album tracks
        $tracksResponse = Invoke-SpotifyApi -Method GET -Path "/albums/$albumId/tracks" -Query @{ limit = 50 }
        if (-not $tracksResponse -or -not $tracksResponse.items) {
            Write-Host "❌ Could not get album tracks" -ForegroundColor Red
            return
        }
        $addedCount = 0
        $skippedCount = 0
        Write-Host "📀 Adding $($tracksResponse.items.Count) tracks to queue..." -ForegroundColor Gray
        foreach ($track in $tracksResponse.items) {
            if ($track -and $track.uri -and $track.uri.StartsWith("spotify:track:")) {
                try {
                    # Add track to queue
                    $query = @{ uri = $track.uri }
                    Invoke-SpotifyApi -Method POST -Path "/me/player/queue" -Query $query | Out-Null
                    $addedCount++
                    # Small delay to avoid rate limiting
                    Start-Sleep -Milliseconds 100
                } catch {
                    $skippedCount++
                    Write-Verbose "Skipped track: $($track.name)"
                }
            } else {
                $skippedCount++
            }
        }
        Write-Host "✅ Added $addedCount tracks from '$albumName' to queue" -ForegroundColor Green
        Write-Host "👤 Artist: $artists" -ForegroundColor Yellow
        if ($skippedCount -gt 0) {
            Write-Host "⚠️ Skipped $skippedCount unavailable tracks" -ForegroundColor Yellow
        }
        # Show helpful tips
        Write-Host "💡 Use 'queue' to see current queue" -ForegroundColor Gray
        Write-Host "💡 Use 'next' to skip to queued tracks" -ForegroundColor Gray
    } catch {
        Write-Host "❌ Could not queue album: $($_.Exception.Message)" -ForegroundColor Red
        # Provide helpful error context
        if ($_.Exception.Message -like "*403*") {
            Write-Host "💡 This feature requires Spotify Premium" -ForegroundColor Yellow
        } elseif ($_.Exception.Message -like "*404*") {
            Write-Host "💡 Make sure Spotify is running on an active device" -ForegroundColor Yellow
        }
    }
}
function Start-InteractiveMode {
    <#
    .SYNOPSIS
    Start interactive navigation mode for search results
    .DESCRIPTION
    Provides arrow key navigation through search results with keyboard shortcuts:
    - ↑↓ Navigate through items
    - Enter: Play selected item
    - Space: Add selected item to queue
    - 1-9: Jump to numbered item
    - Escape: Exit interactive mode
    .PARAMETER Items
    Array of items to navigate (tracks, episodes, albums, playlists)
    .PARAMETER Title
    Title to display for the interactive session
    .EXAMPLE
    Start-InteractiveMode -Items $script:SessionTracks -Title "Search Results"
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        [string]$Title = "Interactive Navigation"
    )
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "❌ No items to navigate" -ForegroundColor Red
        return
    }
    # Check terminal capabilities
    $capabilities = Get-TerminalCapabilities
    if (-not $capabilities.SupportsInteractiveInput) {
        Write-Host "⚠️ Interactive navigation not supported in this terminal" -ForegroundColor Yellow
        Write-Host "💡 Use numbered commands instead: play 1, queue 2, etc." -ForegroundColor Cyan
        return
    }
    $selectedIndex = 0
    $maxIndex = $Items.Count - 1
    Write-Host ""
    Write-Host "🎮 $Title - Interactive Mode" -ForegroundColor Cyan
    Write-Host "Use ↑↓ to navigate, Enter to play, Space to queue, Escape to exit" -ForegroundColor Gray
    Write-Host ""
    while ($true) {
        # Clear previous display and show current selection
        Clear-Host
        Write-Host "🎮 $Title - Interactive Mode" -ForegroundColor Cyan
        Write-Host "Use ↑↓ to navigate, Enter to play, Space to queue, Escape to exit" -ForegroundColor Gray
        Write-Host ""
        # Display items with selection highlight
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $isSelected = ($i -eq $selectedIndex)
            $prefix = if ($isSelected) { "► " } else { "  " }
            $color = if ($isSelected) { "Yellow" } else { "White" }
            $displayText = Format-InteractiveItem -Item $item -Index ($i + 1)
            Write-Host "$prefix$displayText" -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "Selected: $(($selectedIndex + 1))/$($Items.Count)" -ForegroundColor Gray
        # Read key input
        try {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            switch ($key.VirtualKeyCode) {
                38 { # Up arrow
                    $selectedIndex = if ($selectedIndex -gt 0) { $selectedIndex - 1 } else { $maxIndex }
                }
                40 { # Down arrow
                    $selectedIndex = if ($selectedIndex -lt $maxIndex) { $selectedIndex + 1 } else { 0 }
                }
                13 { # Enter - Play selected item
                    $selectedItem = $Items[$selectedIndex]
                    Write-Host ""
                    Write-Host "▶️ Playing item $(($selectedIndex + 1))..." -ForegroundColor Green
                    if ($selectedItem.uri) {
                        try {
                            # Handle different types of items
                            if ($selectedItem.type -eq "playlist" -or $selectedItem.search_type -eq "playlist") {
                                # For playlists, use context_uri
                                $body = @{ context_uri = $selectedItem.uri }
                                Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
                                Write-Host "✅ Started playlist playback: $($selectedItem.name)" -ForegroundColor Green
                            } elseif ($selectedItem.type -eq "album" -or $selectedItem.search_type -eq "album") {
                                # For albums, use context_uri
                                $body = @{ context_uri = $selectedItem.uri }
                                Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
                                Write-Host "✅ Started album playback: $($selectedItem.name)" -ForegroundColor Green
                            } else {
                                # For tracks and episodes, use uris
                                $body = @{ uris = @($selectedItem.uri) }
                                Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
                                Write-Host "✅ Started playback: $($selectedItem.name)" -ForegroundColor Green
                            }
                        } catch {
                            Write-Host "❌ Playback failed: $($_.Exception.Message)" -ForegroundColor Red
                            # Provide helpful error context
                            if ($_.Exception.Message -like "*403*") {
                                Write-Host "💡 This feature requires Spotify Premium" -ForegroundColor Yellow
                            } elseif ($_.Exception.Message -like "*404*") {
                                Write-Host "💡 Make sure Spotify is running on an active device" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        Write-Host "❌ No URI available for this item" -ForegroundColor Red
                    }
                    Start-Sleep -Seconds 1
                }
                32 { # Space - Add to queue
                    $selectedItem = $Items[$selectedIndex]
                    Write-Host ""
                    Write-Host "➕ Adding item $(($selectedIndex + 1)) to queue..." -ForegroundColor Cyan
                    if ($selectedItem.uri) {
                        try {
                            # Get current queue size before adding
                            $queueBefore = $null
                            try {
                                $queueBefore = Invoke-SpotifyApi -Method GET -Path "/me/player/queue"
                            } catch {
                                # Ignore queue check errors
                            }
                            # Handle different types of items
                            if ($selectedItem.type -eq "playlist" -or $selectedItem.search_type -eq "playlist") {
                                # For playlists, add all tracks to queue
                                Write-Host "📚 Adding playlist '$($selectedItem.name)' to queue..." -ForegroundColor Cyan
                                # Get playlist tracks
                                $playlistId = $selectedItem.id
                                $tracksResponse = Invoke-SpotifyApi -Method GET -Path "/playlists/$playlistId/tracks" -Query @{ limit = 50 }
                                if ($tracksResponse -and $tracksResponse.items) {
                                    $addedCount = 0
                                    $skippedCount = 0
                                    foreach ($trackItem in $tracksResponse.items) {
                                        $track = $trackItem.track
                                        if ($track -and $track.uri -and $track.uri.StartsWith("spotify:track:")) {
                                            try {
                                                $query = @{ uri = $track.uri }
                                                Invoke-SpotifyApi -Method POST -Path "/me/player/queue" -Query $query | Out-Null
                                                $addedCount++
                                                Start-Sleep -Milliseconds 100  # Rate limiting
                                            } catch {
                                                $skippedCount++
                                            }
                                        } else {
                                            $skippedCount++
                                        }
                                    }
                                    Write-Host "✅ Added $addedCount tracks from playlist to queue" -ForegroundColor Green
                                    if ($skippedCount -gt 0) {
                                        Write-Host "⚠️ Skipped $skippedCount unavailable tracks" -ForegroundColor Yellow
                                    }
                                } else {
                                    Write-Host "❌ Could not get playlist tracks" -ForegroundColor Red
                                }
                            } else {
                                # For individual tracks and episodes
                                # Use Query parameter instead of Body for queue API
                                $query = @{ uri = $selectedItem.uri }
                                Invoke-SpotifyApi -Method POST -Path "/me/player/queue" -Query $query | Out-Null
                                Write-Host "✅ Added to queue" -ForegroundColor Green
                                # Show what was added for better feedback
                                if ($selectedItem.search_type -eq "episode" -or $selectedItem.type -eq "episode") {
                                    Write-Host "🎙️ Added: $($selectedItem.name) from $($selectedItem.show.name)" -ForegroundColor Magenta
                                } else {
                                    $artists = ($selectedItem.artists | ForEach-Object { $_.name }) -join ", "
                                    Write-Host "🎵 Added: $($selectedItem.name) by $artists" -ForegroundColor Cyan
                                }
                                # Show queue position info
                                if ($queueBefore -and $queueBefore.queue) {
                                    $queuePosition = $queueBefore.queue.Count + 1
                                    Write-Host "📍 Position in queue: #$queuePosition" -ForegroundColor Gray
                                }
                            }
                            Write-Host "💡 Use 'queue' command to see full queue" -ForegroundColor Gray
                        } catch {
                            Write-Host "❌ Queue failed: $($_.Exception.Message)" -ForegroundColor Red
                            # Provide helpful error context
                            if ($_.Exception.Message -like "*403*") {
                                Write-Host "💡 This feature requires Spotify Premium" -ForegroundColor Yellow
                            } elseif ($_.Exception.Message -like "*404*") {
                                Write-Host "💡 Make sure Spotify is running on an active device" -ForegroundColor Yellow
                            } elseif ($_.Exception.Message -like "*401*") {
                                Write-Host "💡 Authentication expired - run .\spotifyCLI.ps1 to re-authenticate" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        Write-Host "❌ No URI available for this item" -ForegroundColor Red
                    }
                    Start-Sleep -Seconds 2  # Give more time to read the feedback
                }
                27 { # Escape - Exit
                    Write-Host ""
                    Write-Host "👋 Exiting interactive mode" -ForegroundColor Yellow
                    return
                }
                default {
                    # Check for number keys (1-9)
                    if ($key.Character -ge '1' -and $key.Character -le '9') {
                        $targetIndex = [int]$key.Character - 1
                        if ($targetIndex -lt $Items.Count) {
                            $selectedIndex = $targetIndex
                        }
                    }
                }
            }
        } catch {
            Write-Host "❌ Interactive input error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "💡 Try using numbered commands instead" -ForegroundColor Yellow
            return
        }
    }
}
function Format-InteractiveItem {
    <#
    .SYNOPSIS
    Format an item for display in interactive mode
    .PARAMETER Item
    The item to format (track, episode, album, playlist)
    .PARAMETER Index
    The display index number
    #>
    param(
        [Parameter(Mandatory)]
        $Item,
        [int]$Index
    )
    if (-not $Item) {
        return "$Index. [Unknown Item]"
    }
    # Determine item type and format accordingly
    $itemType = $Item.type
    if ($Item.search_type) {
        $itemType = $Item.search_type
    }
    switch ($itemType) {
        "track" {
            $artists = if ($Item.artists) {
                ($Item.artists | ForEach-Object { $_.name }) -join ", "
            } else {
                "Unknown Artist"
            }
            return "$Index. 🎵 $($Item.name) - $artists"
        }
        "episode" {
            $showName = if ($Item.show -and $Item.show.name) {
                $Item.show.name
            } else {
                "Unknown Show"
            }
            return "$Index. 🎙️ $($Item.name) - $showName"
        }
        "album" {
            $artists = if ($Item.artists) {
                ($Item.artists | ForEach-Object { $_.name }) -join ", "
            } else {
                "Unknown Artist"
            }
            return "$Index. 💿 $($Item.name) - $artists"
        }
        "playlist" {
            $owner = if ($Item.owner -and $Item.owner.display_name) {
                $Item.owner.display_name
            } else {
                "Unknown Owner"
            }
            return "$Index. 📋 $($Item.name) by $owner"
        }
        default {
            return "$Index. $($Item.name)"
        }
    }
}
function Test-InteractiveNavigation {
    <#
    .SYNOPSIS
    Test interactive navigation functionality
    .DESCRIPTION
    Creates mock data and tests the interactive navigation system
    #>
    Write-Host "🧪 Testing Interactive Navigation" -ForegroundColor Cyan
    Write-Host ""
    # Create mock test data
    $mockItems = @(
        @{
            name = "Bohemian Rhapsody"
            type = "track"
            artists = @(@{ name = "Queen" })
            uri = "spotify:track:1234567890"
        },
        @{
            name = "The Joe Rogan Experience #1234"
            type = "episode"
            search_type = "episode"
            show = @{ name = "The Joe Rogan Experience" }
            uri = "spotify:episode:0987654321"
        },
        @{
            name = "Dark Side of the Moon"
            type = "album"
            artists = @(@{ name = "Pink Floyd" })
            uri = "spotify:album:5555555555"
        }
    )
    Write-Host "Mock data created with $($mockItems.Count) items" -ForegroundColor Green
    Write-Host "Testing interactive mode with mock data..." -ForegroundColor Gray
    # Test the interactive mode
    Start-InteractiveMode -Items $mockItems -Title "Test Navigation"
}
function Get-SpotifyCliTroubleshootingGuide {
    <#
    .SYNOPSIS
    Display comprehensive troubleshooting guide for cross-platform issues
    #>
    param(
        [string]$Category = "All"  # All, Environment, Interactive, Notifications, Authentication
    )
    Write-Host "🔧 Spotify CLI - Cross-Platform Troubleshooting Guide" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""
    if ($Category -eq "All" -or $Category -eq "Environment") {
        Write-Host "ENVIRONMENT ISSUES:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "PowerShell ISE - Limited Interactive Support:" -ForegroundColor White
        Write-Host "  Problem: Arrow keys don't work in interactive mode" -ForegroundColor Gray
        Write-Host "  Solution: Use numbered commands instead (play 1, queue 2)" -ForegroundColor Green
        Write-Host "  Enable: Set-SpotifyConfig @{CompactMode=`$true}" -ForegroundColor Green
        Write-Host ""
        Write-Host "Windows PowerShell 5.1 - Module Loading:" -ForegroundColor White
        Write-Host "  Problem: 'region' command not recognized" -ForegroundColor Gray
        Write-Host "  Solution: Update to latest module version" -ForegroundColor Green
        Write-Host "  Enable TLS: [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12" -ForegroundColor Green
        Write-Host ""
        Write-Host "VS Code Terminal - Split Window:" -ForegroundColor White
        Write-Host "  Problem: Cannot create split programmatically" -ForegroundColor Gray
        Write-Host "  Solution: Use Ctrl+Shift+5 to split manually" -ForegroundColor Green
        Write-Host "  Alternative: Start-SpotifyCliInNewWindow" -ForegroundColor Green
        Write-Host ""
    }
    if ($Category -eq "All" -or $Category -eq "Interactive") {
        Write-Host "INTERACTIVE NAVIGATION ISSUES:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Arrow Keys Not Working:" -ForegroundColor White
        Write-Host "  Check: Show-TerminalCapabilities" -ForegroundColor Green
        Write-Host "  Fallback: Use number keys (1-9) for direct selection" -ForegroundColor Green
        Write-Host "  Exit: Press Escape or Ctrl+C if stuck" -ForegroundColor Green
        Write-Host ""
        Write-Host "Interactive Mode Freezes:" -ForegroundColor White
        Write-Host "  Cause: Terminal doesn't support interactive input" -ForegroundColor Gray
        Write-Host "  Solution: Use traditional numbered commands" -ForegroundColor Green
        Write-Host "  Example: search 'artist'; play 1; queue 2" -ForegroundColor Green
        Write-Host ""
    }
    if ($Category -eq "All" -or $Category -eq "Notifications") {
        Write-Host "NOTIFICATION ISSUES:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Toast Notifications Not Appearing:" -ForegroundColor White
        Write-Host "  Install: Install-Module BurntToast -Force" -ForegroundColor Green
        Write-Host "  Test: notifications test" -ForegroundColor Green
        Write-Host "  Windows Settings: Enable notifications for PowerShell" -ForegroundColor Green
        Write-Host ""
        Write-Host "BurntToast Installation Fails:" -ForegroundColor White
        Write-Host "  Alternative: Add-Type -AssemblyName Windows.UI" -ForegroundColor Green
        Write-Host "  Fallback: Console notifications always work" -ForegroundColor Green
        Write-Host ""
    }
    if ($Category -eq "All" -or $Category -eq "Authentication") {
        Write-Host "AUTHENTICATION ISSUES:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Token Refresh Fails:" -ForegroundColor White
        Write-Host "  Clear: Remove-Item \"`$env:APPDATA\SpotifyCLI\tokens.json\" -Force" -ForegroundColor Green
        Write-Host "  Re-auth: ./spotifyCLI.ps1" -ForegroundColor Green
        Write-Host ""
        Write-Host "Environment Variables Missing:" -ForegroundColor White
        Write-Host "  Per-session: `$env:SPOTIFY_CLIENT_ID = \"your_id\"" -ForegroundColor Green
        Write-Host "  Permanent: [Environment]::SetEnvironmentVariable(\"SPOTIFY_CLIENT_ID\", \"your_id\", \"User\")" -ForegroundColor Green
        Write-Host ""
    }
    Write-Host "DIAGNOSTIC COMMANDS:" -ForegroundColor Yellow
    Write-Host "  Show-TerminalCapabilities    - Check environment support" -ForegroundColor White
    Write-Host "  Test-SpotifyCliInstallation  - Verify installation" -ForegroundColor White
    Write-Host "  Test-NotificationSupport     - Test notification system" -ForegroundColor White
    Write-Host "  Test-SplitWindowSupport      - Check split window capability" -ForegroundColor White
    Write-Host "  Test-AliasConflicts          - Check for command conflicts" -ForegroundColor White
    Write-Host ""
    Write-Host "REPAIR COMMANDS:" -ForegroundColor Yellow
    Write-Host "  Repair-SpotifyCliInstallation - Fix installation issues" -ForegroundColor White
    Write-Host "  Install-SpotifyCliDependencies - Install missing modules" -ForegroundColor White
    Write-Host "  Uninstall-SpotifyCli         - Clean removal and reinstall" -ForegroundColor White
    Write-Host ""
    Write-Host "💡 For detailed troubleshooting, see: CROSS-PLATFORM-TROUBLESHOOTING.md" -ForegroundColor Cyan
}
function Get-SpotifyHelp {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Host "🎵 Spotify CLI - Advanced Edition Complete Help" -ForegroundColor Cyan
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "ENHANCED PLAYBACK CONTROLS:" -ForegroundColor Yellow
        Write-Host "  spotify              - Launch Spotify application" -ForegroundColor White
        Write-Host "  plays-now / music / pn - Show current track (detailed)" -ForegroundColor White
        Write-Host "  spotify-now          - Show current track (compact)" -ForegroundColor White
        Write-Host "  play [number]        - Resume playback or play numbered item" -ForegroundColor White
        Write-Host "  pause                - Smart pause/resume toggle" -ForegroundColor White
        Write-Host "  next                 - Skip to next track" -ForegroundColor White
        Write-Host "  previous             - Skip to previous track" -ForegroundColor White
        Write-Host ""
        Write-Host "SMART PLAYLIST & ALBUM MANAGEMENT:" -ForegroundColor Yellow
        Write-Host "  playlists / pl       - Show playlists with numbers" -ForegroundColor White
        Write-Host "  play-playlist <num>  - Play playlist by number" -ForegroundColor White
        Write-Host "  play-playlist <num> <track> - Play specific track from playlist" -ForegroundColor White
        Write-Host "  queue-playlist <num> - Add entire playlist to queue" -ForegroundColor White
        Write-Host "  search-albums '<query>' - Search for albums only" -ForegroundColor White
        Write-Host "  play-album <num>     - Play album by number" -ForegroundColor White
        Write-Host "  queue-album <num>    - Add entire album to queue" -ForegroundColor White
        Write-Host ""
        Write-Host "ENHANCED SEARCH & DISCOVERY:" -ForegroundColor Yellow
        Write-Host "  search '<query>'     - Search tracks, albums, and podcast episodes" -ForegroundColor White
        Write-Host "  queue <num>          - Add numbered item to queue" -ForegroundColor White
        Write-Host "  Interactive Mode:    - Press Enter in search results for arrow key navigation" -ForegroundColor White
        Write-Host "    ↑↓ Navigate, Enter=Play, Space=Queue, p=Playlist, a=Album, s=Save" -ForegroundColor Gray
        Write-Host ""
        Write-Host "ADVANCED CONTROLS:" -ForegroundColor Yellow
        Write-Host "  volume 75 / vol 75   - Set volume to 75%" -ForegroundColor White
        Write-Host "  seek 30              - Seek forward 30 seconds (negative for backward)" -ForegroundColor White
        Write-Host "  shuffle on / sh on   - Enable shuffle (on/off/toggle)" -ForegroundColor White
        Write-Host "  repeat track / rep track - Set repeat mode (track/context/off)" -ForegroundColor White
        Write-Host ""
        Write-Host "DEVICE MANAGEMENT:" -ForegroundColor Yellow
        Write-Host "  devices              - List available Spotify devices with numbers" -ForegroundColor White
        Write-Host "  transfer <num> / tr <num> - Transfer playback to numbered device" -ForegroundColor White
        Write-Host ""
        Write-Host "LIBRARY MANAGEMENT:" -ForegroundColor Yellow
        Write-Host "  liked                - Show your liked songs" -ForegroundColor White
        Write-Host "  recent               - Show recently played tracks and episodes" -ForegroundColor White
        Write-Host "  save-track [num]     - Save current or numbered track/episode" -ForegroundColor White
        Write-Host "  unsave-track [num]   - Remove current or numbered track/episode" -ForegroundColor White
        Write-Host ""
        Write-Host "WINDOW MANAGEMENT:" -ForegroundColor Yellow
        Write-Host "  Start-SpotifyCliInSidecar - Open CLI in split window (Windows Terminal/VS Code)" -ForegroundColor White
        Write-Host "  Start-SpotifyCliInNewWindow - Open CLI in new window" -ForegroundColor White
        Write-Host "  Test-SplitWindowSupport - Check if split windows are supported" -ForegroundColor White
        Write-Host ""
        Write-Host "CROSS-PLATFORM FEATURES:" -ForegroundColor Yellow
        Write-Host "  Show-TerminalCapabilities - Display current terminal capabilities" -ForegroundColor White
        Write-Host "  Test-NotificationSupport - Test notification system" -ForegroundColor White
        Write-Host "  notifications test   - Test all notification methods" -ForegroundColor White
        Write-Host ""
        Write-Host "CONFIGURATION & DIAGNOSTICS:" -ForegroundColor Yellow
        Write-Host "  Get-SpotifyConfig    - View current settings" -ForegroundColor White
        Write-Host "  Set-SpotifyConfig    - Modify settings" -ForegroundColor White
        Write-Host "  Test-SpotifyAuth     - Check authentication status" -ForegroundColor White
        Write-Host "  Test-SpotifyCliInstallation - Verify installation" -ForegroundColor White
        Write-Host ""
        Write-Host "INSTALLATION & MAINTENANCE:" -ForegroundColor Yellow
        Write-Host "  Install-SpotifyCliDependencies - Install required modules" -ForegroundColor White
        Write-Host "  Repair-SpotifyCliInstallation - Fix installation issues" -ForegroundColor White
        Write-Host "  Uninstall-SpotifyCli - Remove CLI completely" -ForegroundColor White
        Write-Host ""
        Write-Host "ALIAS MANAGEMENT:" -ForegroundColor Yellow
        Write-Host "  Get-SpotifyAliases   - Show all configured aliases" -ForegroundColor White
        Write-Host "  Set-SpotifyAlias     - Create custom alias" -ForegroundColor White
        Write-Host "  Remove-SpotifyAlias  - Remove custom alias" -ForegroundColor White
        Write-Host "  Test-AliasConflicts  - Check for PowerShell conflicts" -ForegroundColor White
        Write-Host ""
        Write-Host "HELP & TROUBLESHOOTING:" -ForegroundColor Yellow
        Write-Host "  Get-SpotifyHelp [command] - Show this help or command-specific help" -ForegroundColor White
        Write-Host "  spotify-help         - Short alias for help" -ForegroundColor White
        Write-Host "  Get-SpotifyCliTroubleshootingGuide - Cross-platform troubleshooting" -ForegroundColor White
        Write-Host ""
        Write-Host "EXAMPLES:" -ForegroundColor Green
        Write-Host "  # Launch Spotify and show current track" -ForegroundColor Gray
        Write-Host "  spotify; plays-now" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  # Search and use interactive navigation" -ForegroundColor Gray
        Write-Host "  search 'pink floyd'  # Then press Enter for interactive mode" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  # Playlist management with numbers" -ForegroundColor Gray
        Write-Host "  playlists; play-playlist 1; queue-playlist 2" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  # Album search and playback" -ForegroundColor Gray
        Write-Host "  search-albums 'the beatles'; play-album 1" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  # Cross-platform features" -ForegroundColor Gray
        Write-Host "  Show-TerminalCapabilities; Start-SpotifyCliInSidecar" -ForegroundColor Gray
        Write-Host ""
        Write-Host "💡 TIP: Use 'Get-SpotifyHelp <command>' for detailed help on specific commands" -ForegroundColor Cyan
        return
    }
    switch ($Command.ToLower()) {
        "spotify-now" {
            Write-Host "COMMAND: spotify-now [compact]" -ForegroundColor Cyan
            Write-Host "Shows current track information" -ForegroundColor White
            Write-Host "Use 'compact' for single-line display" -ForegroundColor Gray
        }
        "show-spotifytrack" {
            Write-Host "COMMAND: Show-SpotifyTrack [compact]" -ForegroundColor Cyan
            Write-Host "Shows current track information" -ForegroundColor White
            Write-Host "Use 'compact' for single-line display" -ForegroundColor Gray
        }
        "search" {
            Write-Host "COMMAND: search '<query>'" -ForegroundColor Cyan
            Write-Host "Search for tracks, artists, and albums" -ForegroundColor White
            Write-Host "Example: search 'the beatles'" -ForegroundColor Gray
        }
        "notifications" {
            Write-Host "COMMAND: notifications [on|off|status|test]" -ForegroundColor Cyan
            Write-Host "Control Windows toast notifications for track changes" -ForegroundColor White
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Yellow
            Write-Host "  on      - Enable notifications" -ForegroundColor White
            Write-Host "  off     - Disable notifications" -ForegroundColor White
            Write-Host "  status  - Show current status (default)" -ForegroundColor White
            Write-Host "  test    - Test notification system" -ForegroundColor White
        }
        default {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Write-Host "Available commands for detailed help:" -ForegroundColor Yellow
            Write-Host "  spotify-now, show-spotifytrack, search, notifications" -ForegroundColor White
            Write-Host ""
            Write-Host "Use Get-SpotifyHelp for all commands" -ForegroundColor Yellow
        }
    }
}
function spotify-help {
    param([string]$Command)
    Get-SpotifyHelp $Command
}
function Show-TrackNotification {
    <#
    .SYNOPSIS
    Display a Windows notification for track changes
    .PARAMETER TrackInfo
    Track information object from Spotify API
    .PARAMETER Title
    Custom notification title
    .PARAMETER Message
    Custom notification message
    .PARAMETER IsTest
    Whether this is a test notification
    #>
    param(
        $TrackInfo,
        [string]$Title,
        [string]$Message,
        [bool]$IsTest = $false
    )
    $config = Get-SpotifyConfig
    if (-not $config.NotificationsEnabled -and -not $IsTest) {
        return
    }
    try {
        # Create notification content
        if ($TrackInfo) {
            $trackName = $TrackInfo.name
            $artists = ($TrackInfo.artists | ForEach-Object { $_.name }) -join ", "
            $album = $TrackInfo.album.name
            $notificationTitle = "🎵 Now Playing"
            $notificationText = "$trackName by $artists"
            if ($album) {
                $notificationText += " from $album"
            }
        } else {
            $notificationTitle = if ($Title) { $Title } else { "Spotify CLI" }
            $notificationText = if ($Message) { $Message } else { "Notification" }
        }
        # Try Windows 10+ toast notifications first
        if ([System.Environment]::OSVersion.Version.Major -ge 10) {
            try {
                # Import BurntToast module if available
                Import-Module BurntToast -ErrorAction Stop
                # Use sound for test notifications to make them more noticeable
                if ($IsTest) {
                    $null = New-BurntToastNotification -Text $notificationTitle, $notificationText -Sound 'Default' -ErrorAction Stop
                } else {
                    $null = New-BurntToastNotification -Text $notificationTitle, $notificationText -Silent -ErrorAction Stop
                }
                Write-Verbose "Toast notification sent: $notificationTitle - $notificationText"
                return
            } catch {
                Write-Verbose "BurntToast failed: $($_.Exception.Message)"
                # BurntToast module not available, try alternative approach
            }
            try {
                # Alternative: Use Windows Shell notification
                $shell = New-Object -ComObject "Wscript.Shell"
                $shell.Popup($notificationText, 5, $notificationTitle, 64) | Out-Null
                Write-Verbose "Shell popup notification sent: $notificationTitle - $notificationText"
                return
            } catch {
                Write-Verbose "Shell popup failed: $($_.Exception.Message)"
                # Shell popup failed, continue to fallback
            }
        }
        # Fallback to console notification
        Write-Host "🔔 $notificationTitle`: $notificationText" -ForegroundColor Cyan
        Write-Verbose "Console notification displayed: $notificationTitle - $notificationText"
    } catch {
        # Final fallback to console notification
        if ($TrackInfo) {
            Write-Host "🎵 Now Playing: $($TrackInfo.name) by $(($TrackInfo.artists | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Cyan
        } else {
            Write-Host "🔔 $notificationTitle`: $notificationText" -ForegroundColor Cyan
        }
    }
}
function Test-NotificationSupport {
    <#
    .SYNOPSIS
    Test if Windows notifications are supported on this system
    #>
    try {
        # Check Windows version
        if ([System.Environment]::OSVersion.Version.Major -lt 6) {
            return @{
                Supported = $false
                Reason = "Notifications require Windows Vista or later"
            }
        }
        # Test BurntToast module availability
        try {
            $null = Get-Command New-BurntToastNotification -ErrorAction Stop
            return @{
                Supported = $true
                Reason = "BurntToast module available for toast notifications"
            }
        } catch {
            # BurntToast not available, check for shell popup support
        }
        # Test Windows Shell popup support
        try {
            $shell = New-Object -ComObject "Wscript.Shell" -ErrorAction Stop
            return @{
                Supported = $true
                Reason = "Windows Shell popup notifications available"
            }
        } catch {
            # Shell popup not available
        }
        # At minimum, console notifications are always supported
        return @{
            Supported = $true
            Reason = "Console notifications available (fallback)"
        }
    } catch {
        return @{
            Supported = $true
            Reason = "Console notifications available (fallback)"
        }
    }
}
function notifications {
    <#
    .SYNOPSIS
    Control notification settings
    .PARAMETER Action
    Action to perform: 'on', 'off', 'status', or 'test'
    .EXAMPLE
    notifications on
    Enable notifications
    .EXAMPLE
    notifications test
    Test notification system
    #>
    param(
        [ValidateSet('on', 'off', 'status', 'test')]
        [string]$Action = 'status'
    )
    $config = Get-SpotifyConfig
    switch ($Action.ToLower()) {
        'on' {
            $config.NotificationsEnabled = $true
            if (Set-SpotifyConfig -Config $config) {
                Write-Host "🔔 Notifications enabled" -ForegroundColor Green
                # Test notification support
                $support = Test-NotificationSupport
                if ($support.Supported) {
                    Write-Host "✅ Notification system ready: $($support.Reason)" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ Notification system limited: $($support.Reason)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "❌ Failed to enable notifications" -ForegroundColor Red
            }
        }
        'off' {
            $config.NotificationsEnabled = $false
            if (Set-SpotifyConfig -Config $config) {
                Write-Host "🔕 Notifications disabled" -ForegroundColor Yellow
            } else {
                Write-Host "❌ Failed to disable notifications" -ForegroundColor Red
            }
        }
        'test' {
            Write-Host "🧪 Testing notification system..." -ForegroundColor Cyan
            Show-TrackNotification -Title "Test Notification" -Message "Spotify CLI notification system is working!" -IsTest $true
        }
        'status' {
            $status = if ($config.NotificationsEnabled) { "Enabled" } else { "Disabled" }
            $color = if ($config.NotificationsEnabled) { "Green" } else { "Yellow" }
            Write-Host "🔔 Notifications: $status" -ForegroundColor $color
            if ($config.NotificationsEnabled) {
                $support = Test-NotificationSupport
                Write-Host "📋 System support: $($support.Reason)" -ForegroundColor Gray
            }
        }
    }
}
# Additional functions from CLI that should be available globally
function volume {
    <#
    .SYNOPSIS
    Control Spotify volume
    .PARAMETER Level
    Volume level (0-100)
    .EXAMPLE
    volume 75
    Set volume to 75%
    #>
    param([int]$Level)
    if ($Level -lt 0 -or $Level -gt 100) {
        Write-Host "❌ Volume must be between 0 and 100" -ForegroundColor Red
        return
    }
    try {
        $query = @{ volume_percent = $Level }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/volume" -Query $query | Out-Null
        Write-Host "🔊 Volume set to $Level%" -ForegroundColor Green
    } catch {
        Write-Host "❌ Could not set volume" -ForegroundColor Red
    }
}
function seek {
    <#
    .SYNOPSIS
    Seek in current track or podcast episode
    .PARAMETER Seconds
    Seconds to seek (positive = forward, negative = backward)
    .EXAMPLE
    seek 30
    Seek forward 30 seconds
    .EXAMPLE
    seek -10
    Seek backward 10 seconds
    .EXAMPLE
    seek -30
    Seek backward 30 seconds (useful for podcast replay)
    #>
    param([int]$Seconds)
    try {
        $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
        if (-not $currentTrack -or -not $currentTrack.item) {
            Write-Host "❌ No track or episode currently playing" -ForegroundColor Red
            return
        }
        $item = $currentTrack.item
        $isPodcast = $item.type -eq "episode" -or ($currentTrack.currently_playing_type -eq "episode")
        $currentPosition = $currentTrack.progress_ms
        $newPosition = $currentPosition + ($Seconds * 1000)
        $maxPosition = $item.duration_ms
        # Ensure position is within bounds
        if ($newPosition -lt 0) { $newPosition = 0 }
        if ($newPosition -gt $maxPosition) { $newPosition = $maxPosition }
        $query = @{ position_ms = $newPosition }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/seek" -Query $query | Out-Null
        $direction = if ($Seconds -gt 0) { "forward" } else { "backward" }
        $absSeconds = [Math]::Abs($Seconds)
        if ($isPodcast) {
            Write-Host "⏩ Seeked $direction $absSeconds seconds in podcast episode" -ForegroundColor Magenta
            # Show current position for podcast episodes (more useful for long content)
            $currentTimeStr = Format-Time $newPosition
            $totalTimeStr = Format-Time $maxPosition
            Write-Host "📍 Position: $currentTimeStr / $totalTimeStr" -ForegroundColor Gray
        } else {
            Write-Host "⏩ Seeked $direction $absSeconds seconds" -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ Could not seek in current content" -ForegroundColor Red
    }
}
function skip-forward {
    <#
    .SYNOPSIS
    Skip forward 30 seconds (common podcast control)
    .EXAMPLE
    skip-forward
    Skip forward 30 seconds in current episode or track
    #>
    seek 30
}
function skip-back {
    <#
    .SYNOPSIS
    Skip backward 15 seconds (common podcast control)
    .EXAMPLE
    skip-back
    Skip backward 15 seconds in current episode or track
    #>
    seek -15
}
function replay {
    <#
    .SYNOPSIS
    Skip backward 30 seconds (useful for podcast replay)
    .EXAMPLE
    replay
    Skip backward 30 seconds to replay content
    #>
    seek -30
}
function shuffle {
    <#
    .SYNOPSIS
    Control shuffle mode
    .PARAMETER State
    Shuffle state: 'on', 'off', or 'toggle'
    .EXAMPLE
    shuffle on
    Enable shuffle
    .EXAMPLE
    shuffle toggle
    Toggle shuffle state
    #>
    param([ValidateSet('on', 'off', 'toggle')][string]$State = 'toggle')
    try {
        if ($State -eq 'toggle') {
            # Get current state first
            $currentState = Invoke-SpotifyApi -Method GET -Path "/me/player"
            $currentShuffle = $currentState.shuffle_state
            $newState = -not $currentShuffle
        } else {
            $newState = ($State -eq 'on')
        }
        $query = @{ state = $newState.ToString().ToLower() }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/shuffle" -Query $query | Out-Null
        $stateText = if ($newState) { "enabled" } else { "disabled" }
        $icon = if ($newState) { "🔀" } else { "➡️" }
        Write-Host "$icon Shuffle $stateText" -ForegroundColor Green
    } catch {
        Write-Host "❌ Could not change shuffle state" -ForegroundColor Red
    }
}
function repeat {
    <#
    .SYNOPSIS
    Control repeat mode
    .PARAMETER Mode
    Repeat mode: 'track', 'context', 'off'
    .EXAMPLE
    repeat track
    Repeat current track
    .EXAMPLE
    repeat off
    Disable repeat
    #>
    param([ValidateSet('track', 'context', 'off')][string]$Mode = 'off')
    try {
        $query = @{ state = $Mode }
        Invoke-SpotifyApi -Method PUT -Path "/me/player/repeat" -Query $query | Out-Null
        $icon = switch ($Mode) {
            "track" { "🔂" }
            "context" { "🔁" }
            "off" { "➡️" }
        }
        $modeText = switch ($Mode) {
            "track" { "current track" }
            "context" { "playlist/album" }
            "off" { "disabled" }
        }
        Write-Host "$icon Repeat $modeText" -ForegroundColor Green
    } catch {
        Write-Host "❌ Could not change repeat mode" -ForegroundColor Red
    }
}
function transfer {
    <#
    .SYNOPSIS
    Transfer playback to another device
    .PARAMETER DeviceId
    Device ID or number (from devices list) to transfer to
    .EXAMPLE
    transfer 1
    Transfer playback to device #1 from devices list
    .EXAMPLE
    transfer abc123
    Transfer playback to device with ID abc123
    #>
    param([string]$DeviceId)
    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        Write-Host "Usage: transfer <device_number_or_id>" -ForegroundColor Yellow
        Write-Host "Use 'devices' command to see available devices" -ForegroundColor Gray
        return
    }
    $actualDeviceId = $DeviceId
    # Check if it's a number (device index)
    if ($DeviceId -match '^\d+$') {
        $deviceIndex = [int]$DeviceId - 1
        if ($script:SessionDevices -and $deviceIndex -ge 0 -and $deviceIndex -lt $script:SessionDevices.Count) {
            $actualDeviceId = $script:SessionDevices[$deviceIndex].id
            $deviceName = $script:SessionDevices[$deviceIndex].name
            Write-Host "🎯 Transferring to device #$DeviceId ($deviceName)..." -ForegroundColor Cyan
        } else {
            Write-Host "❌ Invalid device number. Use 'devices' to see available devices." -ForegroundColor Red
            return
        }
    }
    # If it's not a number, validate that the device ID exists
    if (-not ($DeviceId -match '^\d+$')) {
        # Get current devices to validate the ID
        try {
            $devicesResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/devices"
            if ($devicesResponse -and $devicesResponse.devices) {
                $validDevice = $devicesResponse.devices | Where-Object { $_.id -eq $actualDeviceId }
                if (-not $validDevice) {
                    Write-Host "❌ Device ID '$actualDeviceId' not found in available devices." -ForegroundColor Red
                    Write-Host "Use 'devices' command to see available device IDs" -ForegroundColor Gray
                    return
                }
                Write-Host "🎯 Transferring to device '$($validDevice.name)'..." -ForegroundColor Cyan
            }
        } catch {
            Write-Host "❌ Could not validate device ID" -ForegroundColor Red
            return
        }
    }
    try {
        $body = @{ device_ids = @($actualDeviceId) }
        Invoke-SpotifyApi -Method PUT -Path "/me/player" -Body $body | Out-Null
        Write-Host "📱 Playback transferred successfully" -ForegroundColor Green
    } catch {
        Write-Host "❌ Could not transfer playback" -ForegroundColor Red
        Write-Host "Make sure the device is online and available" -ForegroundColor Gray
    }
}
function queue {
    <#
    .SYNOPSIS
    Manage playback queue - display, add, clear, or remove tracks
    .DESCRIPTION
    Advanced queue management with multiple operations:
    - Display current queue (no parameters)
    - Add track by number or URI
    - Clear entire queue
    - Remove specific tracks from queue
    .PARAMETER Operation
    The first operation parameter (optional)
    .PARAMETER SecondArg
    The second argument for operations like 'remove <number>' (optional)
    .EXAMPLE
    queue
    Display current queue with track numbers
    .EXAMPLE
    queue 1
    Add track #1 from search results to queue
    .EXAMPLE
    queue clear
    Clear the entire queue
    .EXAMPLE
    queue remove 3
    Remove track #3 from the queue
    .EXAMPLE
    queue spotify:track:4iV5W9uYEdYUVa79Axb7Rh
    Add track to queue by URI
    #>
    param(
        [string]$Operation,
        [string]$SecondArg
    )
    # If no operation specified, display current queue
    if ([string]::IsNullOrWhiteSpace($Operation)) {
        Show-SpotifyQueue
        return
    }
    $operation = $Operation.ToLower()
    # Handle different operations
    switch ($operation) {
        "clear" {
            Clear-SpotifyQueue
            return
        }
        "remove" {
            if ([string]::IsNullOrWhiteSpace($SecondArg)) {
                Write-Host "❌ Usage: queue remove <track_number>" -ForegroundColor Red
                Write-Host "💡 Use 'queue' to see track numbers" -ForegroundColor Yellow
                return
            }
            Remove-SpotifyQueueTrack -TrackNumber $SecondArg
            return
        }
        default {
            # Add track to queue (existing functionality)
            Add-SpotifyQueueTrack -TrackReference $operation
        }
    }
}
function Show-SpotifyQueue {
    <#
    .SYNOPSIS
    Display the current Spotify queue with track numbers
    #>
    try {
        # Get current queue from Spotify API
        $queueResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/queue"
        if (-not $queueResponse) {
            Write-Host "❌ Could not retrieve queue information" -ForegroundColor Red
            return
        }
        Write-Host "🎵 Current Queue:" -ForegroundColor Cyan
        Write-Host ""
        # Show currently playing track
        if ($queueResponse.currently_playing) {
            $current = $queueResponse.currently_playing
            $isPodcast = $current.type -eq "episode"
            if ($isPodcast) {
                Write-Host "▶️ Now Playing: 🎙️ $($current.name)" -ForegroundColor Green
                Write-Host "   from $($current.show.name)" -ForegroundColor Gray
            } else {
                $artists = ($current.artists | ForEach-Object { $_.name }) -join ", "
                Write-Host "▶️ Now Playing: $($current.name)" -ForegroundColor Green
                Write-Host "   by $artists • $($current.album.name)" -ForegroundColor Gray
            }
            Write-Host ""
        }
        # Show queued tracks
        if ($queueResponse.queue -and $queueResponse.queue.Count -gt 0) {
            Write-Host "📋 Up Next:" -ForegroundColor Yellow
            Write-Host ""
            $i = 1
            foreach ($track in $queueResponse.queue) {
                $isPodcast = $track.type -eq "episode"
                if ($isPodcast) {
                    Write-Host "$i. 🎙️ $($track.name)" -ForegroundColor Magenta
                    Write-Host "   from $($track.show.name)" -ForegroundColor Gray
                } else {
                    $artists = ($track.artists | ForEach-Object { $_.name }) -join ", "
                    Write-Host "$i. $($track.name)" -ForegroundColor White
                    Write-Host "   by $artists • $($track.album.name)" -ForegroundColor Gray
                }
                # Show duration
                if ($track.duration_ms) {
                    $duration = Format-Time $track.duration_ms
                    Write-Host "   ⏱ $duration" -ForegroundColor Gray
                }
                Write-Host ""
                $i++
                # Limit display to first 20 tracks to avoid overwhelming output
                if ($i -gt 20) {
                    $remaining = $queueResponse.queue.Count - 20
                    Write-Host "   ... and $remaining more tracks" -ForegroundColor Gray
                    break
                }
            }
            Write-Host "💡 Use 'queue remove <number>' to remove specific tracks" -ForegroundColor Cyan
            Write-Host "💡 Use 'queue clear' to clear entire queue" -ForegroundColor Cyan
        } else {
            Write-Host "📭 Queue is empty" -ForegroundColor Yellow
            Write-Host "💡 Use 'search' then 'queue <number>' to add tracks" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "❌ Could not retrieve queue: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Make sure Spotify is running and you're logged in" -ForegroundColor Yellow
    }
}
function Clear-SpotifyQueue {
    <#
    .SYNOPSIS
    Clear the entire Spotify queue
    #>
    try {
        # Note: Spotify Web API doesn't have a direct "clear queue" endpoint
        # We need to get the queue and remove tracks individually
        Write-Host "🧹 Clearing Spotify queue..." -ForegroundColor Yellow
        $queueResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/queue"
        if (-not $queueResponse -or -not $queueResponse.queue -or $queueResponse.queue.Count -eq 0) {
            Write-Host "📭 Queue is already empty" -ForegroundColor Green
            return
        }
        # Unfortunately, Spotify Web API doesn't provide a way to remove tracks from queue
        # This is a limitation of the Spotify Web API itself
        Write-Host "⚠️ Spotify Web API doesn't support clearing the queue directly" -ForegroundColor Yellow
        Write-Host "💡 Alternative solutions:" -ForegroundColor Cyan
        Write-Host "   • Skip to end of queue using next/previous controls" -ForegroundColor White
        Write-Host "   • Start playing a different playlist/album to replace queue" -ForegroundColor White
        Write-Host "   • Use Spotify app directly to clear queue" -ForegroundColor White
        # Show current queue size
        Write-Host "📊 Current queue has $($queueResponse.queue.Count) tracks" -ForegroundColor Gray
    } catch {
        Write-Host "❌ Could not clear queue: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Remove-SpotifyQueueTrack {
    <#
    .SYNOPSIS
    Remove a specific track from the Spotify queue by number
    #>
    param([string]$TrackNumber)
    if (-not ($TrackNumber -match '^\d+$')) {
        Write-Host "❌ Invalid track number. Must be a number." -ForegroundColor Red
        return
    }
    try {
        Write-Host "🗑️ Attempting to remove track #$TrackNumber from queue..." -ForegroundColor Yellow
        # Unfortunately, Spotify Web API doesn't provide a way to remove specific tracks from queue
        # This is a limitation of the Spotify Web API itself
        Write-Host "⚠️ Spotify Web API doesn't support removing specific tracks from queue" -ForegroundColor Yellow
        Write-Host "💡 Alternative solutions:" -ForegroundColor Cyan
        Write-Host "   • Use 'queue' to see current queue" -ForegroundColor White
        Write-Host "   • Skip tracks using 'next' command" -ForegroundColor White
        Write-Host "   • Use Spotify app directly to manage queue" -ForegroundColor White
    } catch {
        Write-Host "❌ Could not remove track from queue: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Add-SpotifyQueueTrack {
    <#
    .SYNOPSIS
    Add a track to the Spotify queue by number or URI
    #>
    param([string]$TrackReference)
    if ([string]::IsNullOrWhiteSpace($TrackReference)) {
        Write-Host "❌ Usage: queue <track_number_or_uri>" -ForegroundColor Red
        Write-Host "💡 Use 'search' command to find tracks first" -ForegroundColor Yellow
        return
    }
    $trackUri = $TrackReference
    $trackName = ""
    $artistInfo = ""
    # Check if it's a number (track index from search)
    if ($TrackReference -match '^\d+$') {
        $trackIndex = [int]$TrackReference - 1
        if ($script:SessionTracks -and $trackIndex -ge 0 -and $trackIndex -lt $script:SessionTracks.Count) {
            $item = $script:SessionTracks[$trackIndex]
            $trackUri = $item.uri
            $trackName = $item.name
            # Handle both tracks and episodes
            if ($item.search_type -eq "episode" -or $item.type -eq "episode") {
                $artistInfo = "from $($item.show.name)"
                Write-Host "🎯 Adding podcast episode #$TrackReference ($trackName $artistInfo) to queue..." -ForegroundColor Magenta
            } else {
                $artistInfo = "by " + (($item.artists | ForEach-Object { $_.name }) -join ", ")
                Write-Host "🎯 Adding track #$TrackReference ($trackName $artistInfo) to queue..." -ForegroundColor Cyan
            }
        } else {
            Write-Host "❌ Invalid track number. Use 'search' to find tracks first." -ForegroundColor Red
            return
        }
    }
    # Ensure it's a valid Spotify URI (track or episode)
    if (-not ($trackUri.StartsWith("spotify:track:") -or $trackUri.StartsWith("spotify:episode:"))) {
        Write-Host "❌ Invalid URI. Must be a Spotify track or episode URI" -ForegroundColor Red
        return
    }
    try {
        $query = @{ uri = $trackUri }
        Invoke-SpotifyApi -Method POST -Path "/me/player/queue" -Query $query | Out-Null
        if ($trackUri.StartsWith("spotify:episode:")) {
            Write-Host "➕ Podcast episode added to queue" -ForegroundColor Magenta
        } else {
            Write-Host "➕ Track added to queue" -ForegroundColor Green
        }
        # Show helpful tip
        Write-Host "💡 Use 'queue' to see current queue" -ForegroundColor Gray
    } catch {
        Write-Host "❌ Could not add to queue: $($_.Exception.Message)" -ForegroundColor Red
        # Provide helpful error context
        if ($_.Exception.Message -like "*403*") {
            Write-Host "💡 This feature requires Spotify Premium" -ForegroundColor Yellow
        } elseif ($_.Exception.Message -like "*404*") {
            Write-Host "💡 Make sure Spotify is running on an active device" -ForegroundColor Yellow
        }
    }
}
function playlists {
    <#
    .SYNOPSIS
    Show user's playlists with smart numbering
    .EXAMPLE
    playlists
    Show your playlists
    .EXAMPLE
    pl
    Show your playlists (alias)
    #>
    try {
        $playlistsResponse = Invoke-SpotifyApi -Method GET -Path "/me/playlists" -Query @{ limit = 20 }
        if (-not $playlistsResponse -or -not $playlistsResponse.items) {
            Write-Host "No playlists found" -ForegroundColor Yellow
            # Clear session playlists if no results
            $script:SessionPlaylists = @()
            return
        }
        # Store playlists in session for smart numbering
        $script:SessionPlaylists = $playlistsResponse.items
        Write-Host "📚 Your Playlists:" -ForegroundColor Cyan
        Write-Host ""
        $i = 1
        foreach ($playlist in $playlistsResponse.items) {
            $trackCount = $playlist.tracks.total
            $owner = $playlist.owner.display_name
            $isOwn = $playlist.owner.id -eq $playlistsResponse.items[0].owner.id
            $ownerText = if ($isOwn) { "You" } else { $owner }
            Write-Host "$i. $($playlist.name)" -ForegroundColor White
            Write-Host "   $trackCount tracks • by $ownerText" -ForegroundColor Gray
            Write-Host "   URI: $($playlist.uri)" -ForegroundColor Gray
            Write-Host ""
            $i++
        }
        Write-Host "💡 Use 'play-playlist <number>' to play a playlist" -ForegroundColor Cyan
        Write-Host "💡 Use 'play-playlist <number> <track>' to play specific track" -ForegroundColor Cyan
        Write-Host "💡 Use 'queue-playlist <number>' to add playlist to queue" -ForegroundColor Cyan
        Write-Host "🎮 Press Enter for interactive navigation mode..." -ForegroundColor Cyan
        # Check if user wants to enter interactive mode
        $capabilities = Get-TerminalCapabilities
        if ($capabilities.SupportsInteractiveInput) {
            try {
                $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                if ($key.VirtualKeyCode -eq 13) { # Enter key
                    # Prepare playlist items for interactive mode
                    $interactiveItems = @()
                    $i = 0
                    foreach ($playlist in $playlistsResponse.items) {
                        $trackCount = $playlist.tracks.total
                        $owner = $playlist.owner.display_name
                        $isOwn = $playlist.owner.id -eq $playlistsResponse.items[0].owner.id
                        $ownerText = if ($isOwn) { "You" } else { $owner }
                        $interactiveItems += [PSCustomObject]@{
                            name = $playlist.name
                            uri = $playlist.uri
                            id = $playlist.id
                            type = "playlist"
                            search_type = "playlist"
                            description = "$trackCount tracks • by $ownerText"
                            tracks = @{ total = $trackCount }
                            owner = $playlist.owner
                            display_name = "$($playlist.name) ($trackCount tracks • by $ownerText)"
                        }
                        $i++
                    }
                    Start-InteractiveMode -Items $interactiveItems -Title "Your Playlists"
                }
            } catch {
                # If ReadKey fails, just continue without interactive mode
                Write-Host "ℹ️ Interactive mode not available in this terminal" -ForegroundColor Yellow
            }
        } else {
            Write-Host "ℹ️ Interactive mode not supported in this terminal" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Could not get playlists" -ForegroundColor Red
        $script:SessionPlaylists = @()
    }
}
function play-playlist {
    <#
    .SYNOPSIS
    Play a playlist by number from the playlists list
    .PARAMETER PlaylistNumber
    The number of the playlist from the playlists command
    .PARAMETER TrackNumber
    Optional track number within the playlist to start from
    .EXAMPLE
    play-playlist 1
    Play the first playlist from the list
    .EXAMPLE
    play-playlist 1 5
    Play track #5 from the first playlist
    #>
    param(
        [Parameter(Mandatory)][int]$PlaylistNumber,
        [int]$TrackNumber
    )
    try {
        # Check if we have session playlists
        if (-not $script:SessionPlaylists -or $script:SessionPlaylists.Count -eq 0) {
            Write-Host "❌ No playlists in session. Run 'playlists' first." -ForegroundColor Red
            return
        }
        # Validate playlist number
        if ($PlaylistNumber -lt 1 -or $PlaylistNumber -gt $script:SessionPlaylists.Count) {
            Write-Host "❌ Invalid playlist number. Use 1-$($script:SessionPlaylists.Count)" -ForegroundColor Red
            return
        }
        $playlist = $script:SessionPlaylists[$PlaylistNumber - 1]
        $playlistName = $playlist.name
        $playlistUri = $playlist.uri
        if ($TrackNumber) {
            # Play specific track from playlist
            Write-Host "🎵 Getting tracks from playlist '$playlistName'..." -ForegroundColor Cyan
            # Get playlist tracks
            $playlistId = $playlist.id
            $tracksResponse = Invoke-SpotifyApi -Method GET -Path "/playlists/$playlistId/tracks" -Query @{ limit = 50 }
            if (-not $tracksResponse -or -not $tracksResponse.items) {
                Write-Host "❌ Could not get playlist tracks" -ForegroundColor Red
                return
            }
            # Validate track number
            if ($TrackNumber -lt 1 -or $TrackNumber -gt $tracksResponse.items.Count) {
                Write-Host "❌ Invalid track number. Playlist has $($tracksResponse.items.Count) tracks" -ForegroundColor Red
                return
            }
            $trackItem = $tracksResponse.items[$TrackNumber - 1]
            $track = $trackItem.track
            if (-not $track -or -not $track.uri) {
                Write-Host "❌ Track not available or invalid" -ForegroundColor Red
                return
            }
            # Play specific track
            $body = @{
                context_uri = $playlistUri
                offset = @{ position = $TrackNumber - 1 }
            }
            Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
            $artists = ($track.artists | ForEach-Object { $_.name }) -join ", "
            Write-Host "▶️ Playing track #${TrackNumber}: '$($track.name)' by $artists" -ForegroundColor Green
            Write-Host "📚 From playlist: '$playlistName'" -ForegroundColor Cyan
        } else {
            # Play entire playlist from beginning
            $body = @{ context_uri = $playlistUri }
            Invoke-SpotifyApi -Method PUT -Path "/me/player/play" -Body $body | Out-Null
            Write-Host "▶️ Playing playlist: '$playlistName'" -ForegroundColor Green
            Write-Host "📊 $($playlist.tracks.total) tracks" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "❌ Could not play playlist: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function queue-playlist {
    <#
    .SYNOPSIS
    Add entire playlist to queue by number
    .PARAMETER PlaylistNumber
    The number of the playlist from the playlists command
    .EXAMPLE
    queue-playlist 2
    Add playlist #2 to the queue
    #>
    param([Parameter(Mandatory)][int]$PlaylistNumber)
    try {
        # Check if we have session playlists
        if (-not $script:SessionPlaylists -or $script:SessionPlaylists.Count -eq 0) {
            Write-Host "❌ No playlists in session. Run 'playlists' first." -ForegroundColor Red
            return
        }
        # Validate playlist number
        if ($PlaylistNumber -lt 1 -or $PlaylistNumber -gt $script:SessionPlaylists.Count) {
            Write-Host "❌ Invalid playlist number. Use 1-$($script:SessionPlaylists.Count)" -ForegroundColor Red
            return
        }
        $playlist = $script:SessionPlaylists[$PlaylistNumber - 1]
        $playlistName = $playlist.name
        $playlistId = $playlist.id
        Write-Host "🎵 Adding playlist '$playlistName' to queue..." -ForegroundColor Cyan
        # Get playlist tracks
        $tracksResponse = Invoke-SpotifyApi -Method GET -Path "/playlists/$playlistId/tracks" -Query @{ limit = 50 }
        if (-not $tracksResponse -or -not $tracksResponse.items) {
            Write-Host "❌ Could not get playlist tracks" -ForegroundColor Red
            return
        }
        $addedCount = 0
        $skippedCount = 0
        foreach ($trackItem in $tracksResponse.items) {
            $track = $trackItem.track
            if ($track -and $track.uri -and $track.uri.StartsWith("spotify:track:")) {
                try {
                    # Add track to queue
                    Invoke-SpotifyApi -Method POST -Path "/me/player/queue" -Query @{ uri = $track.uri } | Out-Null
                    $addedCount++
                    # Small delay to avoid rate limiting
                    Start-Sleep -Milliseconds 100
                } catch {
                    $skippedCount++
                    Write-Verbose "Skipped track: $($track.name)"
                }
            } else {
                $skippedCount++
            }
        }
        Write-Host "✅ Added $addedCount tracks from '$playlistName' to queue" -ForegroundColor Green
        if ($skippedCount -gt 0) {
            Write-Host "⚠️ Skipped $skippedCount unavailable tracks" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Could not queue playlist: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function liked {
    <#
    .SYNOPSIS
    Show liked/saved tracks
    .EXAMPLE
    liked
    Show your liked songs
    #>
    try {
        $likedResponse = Invoke-SpotifyApi -Method GET -Path "/me/tracks" -Query @{ limit = 20 }
        if (-not $likedResponse -or -not $likedResponse.items) {
            Write-Host "No liked songs found" -ForegroundColor Yellow
            return
        }
        Write-Host "❤️ Your Liked Songs:" -ForegroundColor Cyan
        Write-Host ""
        $i = 1
        foreach ($item in $likedResponse.items) {
            $track = $item.track
            $artists = ($track.artists | ForEach-Object { $_.name }) -join ", "
            $addedDate = [DateTime]::Parse($item.added_at).ToString("yyyy-MM-dd")
            Write-Host "$i. $($track.name)" -ForegroundColor White
            Write-Host "   by $artists • $($track.album.name)" -ForegroundColor Gray
            Write-Host "   Added: $addedDate • URI: $($track.uri)" -ForegroundColor Gray
            Write-Host ""
            $i++
        }
    } catch {
        Write-Host "❌ Could not get liked songs" -ForegroundColor Red
    }
}
function recent {
    <#
    .SYNOPSIS
    Show recently played tracks
    .EXAMPLE
    recent
    Show recently played tracks
    #>
    try {
        $recentResponse = Invoke-SpotifyApi -Method GET -Path "/me/player/recently-played" -Query @{ limit = 20 }
        if (-not $recentResponse -or -not $recentResponse.items) {
            Write-Host "No recent tracks found" -ForegroundColor Yellow
            return
        }
        Write-Host "🕒 Recently Played:" -ForegroundColor Cyan
        Write-Host ""
        $i = 1
        foreach ($item in $recentResponse.items) {
            $playedDate = [DateTime]::Parse($item.played_at).ToString("yyyy-MM-dd HH:mm")
            if ($item.track) {
                # Music track
                $track = $item.track
                $artists = ($track.artists | ForEach-Object { $_.name }) -join ", "
                Write-Host "$i. $($track.name)" -ForegroundColor White
                Write-Host "   by $artists • $($track.album.name)" -ForegroundColor Gray
                Write-Host "   Played: $playedDate • URI: $($track.uri)" -ForegroundColor Gray
            } elseif ($item.episode) {
                # Podcast episode
                $episode = $item.episode
                Write-Host "$i. 🎙️ $($episode.name)" -ForegroundColor Magenta
                Write-Host "   from $($episode.show.name)" -ForegroundColor Gray
                if ($episode.description) {
                    $description = if ($episode.description.Length -gt 60) {
                        $episode.description.Substring(0, 57) + "..."
                    } else {
                        $episode.description
                    }
                    Write-Host "   📝 $description" -ForegroundColor Gray
                }
                Write-Host "   Played: $playedDate • URI: $($episode.uri)" -ForegroundColor Gray
            }
            Write-Host ""
            $i++
        }
    } catch {
        Write-Host "❌ Could not get recent tracks" -ForegroundColor Red
    }
}
function save-track {
    <#
    .SYNOPSIS
    Save current track or podcast episode to library
    .EXAMPLE
    save-track
    Save the currently playing track or episode
    .EXAMPLE
    save-track 3
    Save item #3 from search results
    #>
    param([string]$ItemReference)
    try {
        $item = $null
        $itemName = ""
        $isEpisode = $false
        if ([string]::IsNullOrWhiteSpace($ItemReference)) {
            # Save currently playing item
            $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
            if (-not $currentTrack -or -not $currentTrack.item) {
                Write-Host "❌ No track or episode currently playing" -ForegroundColor Red
                return
            }
            $item = $currentTrack.item
            $itemName = $item.name
            $isEpisode = $item.type -eq "episode" -or ($currentTrack.currently_playing_type -eq "episode")
        } else {
            # Save item from search results by number
            if ($ItemReference -match '^\d+$') {
                $itemIndex = [int]$ItemReference - 1
                if ($script:SessionTracks -and $itemIndex -ge 0 -and $itemIndex -lt $script:SessionTracks.Count) {
                    $item = $script:SessionTracks[$itemIndex]
                    $itemName = $item.name
                    $isEpisode = $item.search_type -eq "episode" -or $item.type -eq "episode"
                } else {
                    Write-Host "❌ Invalid item number. Use 'search' to find tracks and episodes first." -ForegroundColor Red
                    return
                }
            } else {
                Write-Host "❌ Invalid item reference. Use a number from search results." -ForegroundColor Red
                return
            }
        }
        $itemId = $item.id
        $query = @{ ids = $itemId }
        if ($isEpisode) {
            # Save podcast episode
            Invoke-SpotifyApi -Method PUT -Path "/me/episodes" -Query $query | Out-Null
            Write-Host "❤️ Saved podcast episode '$itemName' to your library" -ForegroundColor Magenta
        } else {
            # Save music track
            Invoke-SpotifyApi -Method PUT -Path "/me/tracks" -Query $query | Out-Null
            Write-Host "❤️ Saved track '$itemName' to your library" -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ Could not save item" -ForegroundColor Red
    }
}
function unsave-track {
    <#
    .SYNOPSIS
    Remove current track or podcast episode from library
    .EXAMPLE
    unsave-track
    Remove the currently playing track or episode from library
    .EXAMPLE
    unsave-track 3
    Remove item #3 from search results from library
    #>
    param([string]$ItemReference)
    try {
        $item = $null
        $itemName = ""
        $isEpisode = $false
        if ([string]::IsNullOrWhiteSpace($ItemReference)) {
            # Unsave currently playing item
            $currentTrack = Invoke-SpotifyApi -Method GET -Path "/me/player/currently-playing"
            if (-not $currentTrack -or -not $currentTrack.item) {
                Write-Host "❌ No track or episode currently playing" -ForegroundColor Red
                return
            }
            $item = $currentTrack.item
            $itemName = $item.name
            $isEpisode = $item.type -eq "episode" -or ($currentTrack.currently_playing_type -eq "episode")
        } else {
            # Unsave item from search results by number
            if ($ItemReference -match '^\d+$') {
                $itemIndex = [int]$ItemReference - 1
                if ($script:SessionTracks -and $itemIndex -ge 0 -and $itemIndex -lt $script:SessionTracks.Count) {
                    $item = $script:SessionTracks[$itemIndex]
                    $itemName = $item.name
                    $isEpisode = $item.search_type -eq "episode" -or $item.type -eq "episode"
                } else {
                    Write-Host "❌ Invalid item number. Use 'search' to find tracks and episodes first." -ForegroundColor Red
                    return
                }
            } else {
                Write-Host "❌ Invalid item reference. Use a number from search results." -ForegroundColor Red
                return
            }
        }
        $itemId = $item.id
        $query = @{ ids = $itemId }
        if ($isEpisode) {
            # Unsave podcast episode
            Invoke-SpotifyApi -Method DELETE -Path "/me/episodes" -Query $query | Out-Null
            Write-Host "💔 Removed podcast episode '$itemName' from your library" -ForegroundColor Yellow
        } else {
            # Unsave music track
            Invoke-SpotifyApi -Method DELETE -Path "/me/tracks" -Query $query | Out-Null
            Write-Host "💔 Removed track '$itemName' from your library" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Could not remove item" -ForegroundColor Red
    }
}
function Test-AliasConflicts {
    <#
    .SYNOPSIS
    Test for alias conflicts with PowerShell built-ins
    .DESCRIPTION
    Checks if any Spotify aliases conflict with existing PowerShell commands
    .EXAMPLE
    Test-AliasConflicts
    Check for conflicts and show recommendations
    #>
    Write-Host "🔍 Checking for alias conflicts..." -ForegroundColor Cyan
    $config = Get-SpotifyConfig
    $conflicts = @()
    foreach ($alias in $config.Aliases.GetEnumerator()) {
        $existingCommand = Get-Command -Name $alias.Key -ErrorAction SilentlyContinue
        # Check for conflicts with built-in PowerShell commands
        if ($existingCommand) {
            $isConflict = $false
            $conflictType = ""
            # Check if it conflicts with built-in cmdlets or functions
            if ($existingCommand.CommandType -in @('Cmdlet', 'Function') -and $existingCommand.Source -eq '') {
                $isConflict = $true
                $conflictType = $existingCommand.CommandType
            }
            # Check if it conflicts with built-in aliases
            elseif ($existingCommand.CommandType -eq 'Alias' -and $existingCommand.Source -eq '') {
                $builtInAliases = @('ls', 'dir', 'cd', 'pwd', 'cat', 'cp', 'mv', 'rm', 'ps', 'kill', 'man', 'help', 'cls', 'clear', 'h', 'r', 'p')
                if ($alias.Key -in $builtInAliases) {
                    $isConflict = $true
                    $conflictType = "Built-in Alias"
                }
            }
            if ($isConflict) {
                $conflicts += @{
                    Alias = $alias.Key
                    Target = $alias.Value
                    Conflicts = $existingCommand.Name
                    Type = $conflictType
                }
            }
        }
    }
    if ($conflicts.Count -eq 0) {
        Write-Host "✅ No conflicts found!" -ForegroundColor Green
        return
    }
    Write-Host "⚠️ Found $($conflicts.Count) conflict(s):" -ForegroundColor Yellow
    Write-Host ""
    foreach ($conflict in $conflicts) {
        Write-Host "  ❌ '$($conflict.Alias)' conflicts with PowerShell $($conflict.Type): $($conflict.Conflicts)" -ForegroundColor Red
        Write-Host "     Intended target: $($conflict.Target)" -ForegroundColor Gray
        # Suggest alternatives
        $alternatives = @("s$($conflict.Alias)", "$($conflict.Alias)s", "my$($conflict.Alias)")
        Write-Host "     Suggested alternatives: $($alternatives -join ', ')" -ForegroundColor Green
        Write-Host ""
    }
    Write-Host "💡 To fix conflicts:" -ForegroundColor Cyan
    Write-Host "1. Remove conflicting alias: Remove-SpotifyAlias -Alias 'sp'" -ForegroundColor White
    Write-Host "2. Create new alias: Set-SpotifyAlias -Alias 'spo' -Command 'Show-SpotifyTrack'" -ForegroundColor White
    Write-Host "3. Or use the full command names instead" -ForegroundColor White
}
function Test-SpotifyAuth {
    <#
    .SYNOPSIS
    Test Spotify authentication status
    .DESCRIPTION
    Checks if you're properly authenticated with Spotify and shows status
    .EXAMPLE
    Test-SpotifyAuth
    Check authentication status
    #>
    Write-Host "🔍 Checking Spotify authentication..." -ForegroundColor Cyan
    # Check if environment variables are set
    if (-not $env:SPOTIFY_CLIENT_ID -or -not $env:SPOTIFY_CLIENT_SECRET) {
        Write-Host "❌ Spotify credentials not found in environment variables" -ForegroundColor Red
        Write-Host "💡 Make sure .env file exists with SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET" -ForegroundColor Yellow
        return $false
    }
    # Check if tokens exist
    $tokens = Get-StoredTokens
    if (-not $tokens.access_token) {
        Write-Host "❌ No access token found" -ForegroundColor Red
        Write-Host "💡 Run .\spotifyCLI.ps1 to authenticate" -ForegroundColor Yellow
        return $false
    }
    # Test API call
    try {
        $profile = Invoke-SpotifyApi -Method GET -Path "/me"
        if ($profile) {
            Write-Host "✅ Authentication successful!" -ForegroundColor Green
            Write-Host "👤 Logged in as: $($profile.display_name)" -ForegroundColor Cyan
            Write-Host "📧 Email: $($profile.email)" -ForegroundColor Gray
            Write-Host "🎵 Subscription: $($profile.product)" -ForegroundColor Gray
            return $true
        } else {
            Write-Host "❌ Authentication failed" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "❌ Authentication test failed" -ForegroundColor Red
        return $false
    }
}
# End Core Commands Section
# Alias management functions
function Initialize-SpotifyAliases {
    <#
    .SYNOPSIS
    Initialize default Spotify command aliases as wrapper functions
    #>
    $config = Get-SpotifyConfig
    # Default aliases if not configured
    if (-not $config.Aliases) {
        $config.Aliases = @{
            'sp' = 'Show-SpotifyTrack'
            'spotify' = 'Start-SpotifyApp'
            'plays-now' = 'Show-SpotifyTrack'
            'music' = 'Show-SpotifyTrack'
            'pn' = 'Show-SpotifyTrack'
            'vol' = 'volume'
            'sh' = 'shuffle'
            'rep' = 'repeat'
            'tr' = 'transfer'
            'q' = 'queue'
            'pl' = 'playlists'
        }
        Set-SpotifyConfig -Config $config | Out-Null
    }
    # Create wrapper functions for each alias
    foreach ($alias in $config.Aliases.GetEnumerator()) {
        $aliasName = $alias.Key
        $targetCommand = $alias.Value
        # Check for conflicts with built-in PowerShell commands
        $existingCommand = Get-Command -Name $aliasName -ErrorAction SilentlyContinue
        if ($existingCommand -and $existingCommand.CommandType -in @('Cmdlet', 'Alias') -and $existingCommand.Source -eq '') {
            Write-Verbose "Skipping alias '$aliasName' - conflicts with built-in PowerShell command"
            continue
        }
        # Always recreate the function to ensure it's current
        try {
            # Create wrapper function dynamically with higher precedence
            $functionBody = @"
function global:$aliasName {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]`$Arguments)
    # Call the target Spotify command directly
    try {
        `$command = Get-Command -Name '$targetCommand' -CommandType Function -Module SpotifyModule -ErrorAction Stop
        if (`$Arguments) {
            & `$command @Arguments
        } else {
            & `$command
        }
    } catch {
        Write-Host "❌ Error calling Spotify command '$targetCommand': `$(`$_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Try running: Import-Module SpotifyModule -Force" -ForegroundColor Yellow
    }
}
"@
            # Execute the function definition
            Invoke-Expression $functionBody
            Write-Verbose "Created wrapper function: $aliasName -> $targetCommand"
        } catch {
            Write-Verbose "Failed to create wrapper function $aliasName`: $($_.Exception.Message)"
        }
    }
}
function Set-SpotifyAlias {
    <#
    .SYNOPSIS
    Set a custom alias for a Spotify command
    .PARAMETER Alias
    The alias name to create
    .PARAMETER Command
    The command the alias should point to
    .EXAMPLE
    Set-SpotifyAlias -Alias 'music' -Command 'Show-SpotifyTrack'
    Create alias 'music' for Show-SpotifyTrack
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Alias,
        [Parameter(Mandatory)]
        [string]$Command
    )
    $config = Get-SpotifyConfig
    if (-not $config.Aliases) {
        $config.Aliases = @{}
    }
    # Validate command exists
    $validCommands = @(
        'Show-SpotifyTrack', 'spotify-now', 'play', 'pause', 'next', 'previous',
        'volume', 'seek', 'shuffle', 'repeat', 'devices', 'transfer',
        'search', 'queue', 'playlists', 'liked', 'recent', 'save-track', 'unsave-track',
        'Get-SpotifyConfig', 'Set-SpotifyConfig', 'Get-SpotifyHelp', 'notifications', 'Test-SpotifyAuth'
    )
    if ($Command -notin $validCommands) {
        Write-Host "❌ Invalid command: $Command" -ForegroundColor Red
        Write-Host "Valid commands: $($validCommands -join ', ')" -ForegroundColor Gray
        return
    }
    # Add to config
    $config.Aliases[$Alias] = $Command
    if (Set-SpotifyConfig -Config $config) {
        # Check for conflicts before creating
        $existingCommand = Get-Command -Name $Alias -ErrorAction SilentlyContinue
        if ($existingCommand -and $existingCommand.CommandType -in @('Cmdlet', 'Function') -and $existingCommand.Source -eq '') {
            Write-Host "⚠️ Warning: Alias '$Alias' conflicts with PowerShell built-in $($existingCommand.CommandType): $($existingCommand.Name)" -ForegroundColor Yellow
            $response = Read-Host "Create anyway? This may cause issues. (y/N)"
            if ($response -ne 'y' -and $response -ne 'Y') {
                Write-Host "❌ Alias creation cancelled" -ForegroundColor Red
                return
            }
        }
        # Create PowerShell alias immediately
        try {
            Set-Alias -Name $Alias -Value $Command -Scope Global -Force
            Write-Host "✅ Created alias '$Alias' → '$Command'" -ForegroundColor Green
        } catch {
            Write-Host "⚠️ Alias saved to config but couldn't create immediately: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Restart PowerShell or reimport the module to activate" -ForegroundColor Gray
        }
    } else {
        Write-Host "❌ Failed to save alias configuration" -ForegroundColor Red
    }
}
function Remove-SpotifyAlias {
    <#
    .SYNOPSIS
    Remove a custom Spotify alias
    .PARAMETER Alias
    The alias name to remove
    .EXAMPLE
    Remove-SpotifyAlias -Alias 'music'
    Remove the 'music' alias
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Alias
    )
    $config = Get-SpotifyConfig
    if (-not $config.Aliases -or -not $config.Aliases.ContainsKey($Alias)) {
        Write-Host "❌ Alias '$Alias' not found" -ForegroundColor Red
        return
    }
    # Remove from config
    $config.Aliases.Remove($Alias)
    if (Set-SpotifyConfig -Config $config) {
        # Remove the wrapper function or alias
        try {
            # Try to remove as function first
            if (Get-Command -Name $Alias -CommandType Function -ErrorAction SilentlyContinue) {
                Remove-Item -Path "Function:\$Alias" -Force -ErrorAction SilentlyContinue
            }
            # Try to remove as alias
            if (Get-Command -Name $Alias -CommandType Alias -ErrorAction SilentlyContinue) {
                Remove-Item -Path "Alias:\$Alias" -Force -ErrorAction SilentlyContinue
            }
            Write-Host "✅ Removed alias '$Alias'" -ForegroundColor Green
        } catch {
            Write-Host "⚠️ Alias removed from config but couldn't remove immediately: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "❌ Failed to save alias configuration" -ForegroundColor Red
    }
}
function Get-SpotifyAliases {
    <#
    .SYNOPSIS
    Show all current Spotify aliases
    .EXAMPLE
    Get-SpotifyAliases
    List all configured aliases
    #>
    $config = Get-SpotifyConfig
    if (-not $config.Aliases -or $config.Aliases.Count -eq 0) {
        Write-Host "No aliases configured" -ForegroundColor Yellow
        return
    }
    Write-Host "🔗 Current Spotify Aliases:" -ForegroundColor Cyan
    Write-Host ""
    $config.Aliases.GetEnumerator() | Sort-Object Key | ForEach-Object {
        $aliasCommand = Get-Command -Name $_.Key -ErrorAction SilentlyContinue
        if ($aliasCommand) {
            # Check if it's a Spotify alias (function or alias pointing to Spotify commands)
            if (($aliasCommand.CommandType -eq 'Function' -and $aliasCommand.Source -eq 'SpotifyModule') -or
                ($aliasCommand.CommandType -eq 'Alias' -and $aliasCommand.Source -eq 'SpotifyModule')) {
                $status = "✅"
                $note = ""
            } elseif ($aliasCommand.CommandType -in @('Cmdlet', 'Function') -and $aliasCommand.Source -eq '') {
                $status = "⚠️"
                $note = " (conflicts with PowerShell built-in)"
            } elseif ($aliasCommand.CommandType -eq 'Alias' -and $aliasCommand.Source -eq '') {
                # Check if it's a built-in PowerShell alias
                $builtInAliases = @('ls', 'dir', 'cd', 'pwd', 'cat', 'cp', 'mv', 'rm', 'ps', 'kill', 'man', 'help', 'cls', 'clear')
                if ($_.Key -in $builtInAliases) {
                    $status = "⚠️"
                    $note = " (conflicts with PowerShell built-in)"
                } else {
                    $status = "✅"
                    $note = ""
                }
            } else {
                $status = "❓"
                $note = " (unknown conflict: $($aliasCommand.CommandType) from $($aliasCommand.Source))"
            }
        } else {
            $status = "❌"
            $note = " (not found)"
        }
        Write-Host "  $status $($_.Key) → $($_.Value)$note" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "Legend:" -ForegroundColor Gray
    Write-Host "  ✅ Working correctly" -ForegroundColor Green
    Write-Host "  ⚠️ Conflicts with PowerShell built-in" -ForegroundColor Yellow
    Write-Host "  ❌ Not available" -ForegroundColor Red
}
# Create default wrapper functions directly
function sp {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        Show-SpotifyTrack @Arguments
    } else {
        Show-SpotifyTrack
    }
}
function spotify {
    <#
    .SYNOPSIS
    Launch the Spotify desktop application
    .DESCRIPTION
    The main 'spotify' command launches the Spotify desktop application.
    This is the primary entry point for starting Spotify from the command line.
    .PARAMETER Web
    Open Spotify Web Player instead of desktop app
    .PARAMETER WaitForReady
    Wait for Spotify to become available after launching
    .EXAMPLE
    spotify
    Launches the Spotify desktop application
    .EXAMPLE
    spotify -Web
    Opens Spotify Web Player in default browser
    #>
    [CmdletBinding()]
    param(
        [switch]$Web,
        [switch]$WaitForReady
    )
    Start-SpotifyApp -Web:$Web -WaitForReady:$WaitForReady
}
function vol {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        volume @Arguments
    } else {
        volume
    }
}
function sh {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        shuffle @Arguments
    } else {
        shuffle
    }
}
function rep {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        repeat @Arguments
    } else {
        repeat
    }
}
function tr {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        transfer @Arguments
    } else {
        transfer
    }
}
function q {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        queue @Arguments
    } else {
        queue
    }
}
function pl {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($Arguments) {
        playlists @Arguments
    } else {
        playlists
    }
}
# Window Management and Terminal Detection Section
function Get-TerminalCapabilities {
    <#
    .SYNOPSIS
    Detect terminal capabilities for split window support and other features
    .DESCRIPTION
    Analyzes the current PowerShell environment to determine what terminal features
    are available, including split window support, interactive input, and visual capabilities.
    .OUTPUTS
    Hashtable with capability information
    #>
    $capabilities = @{
        SupportsColors = $true
        SupportsInteractiveInput = $true
        SupportsSplitWindow = $false
        SupportsToastNotifications = $true
        TerminalType = "Unknown"
        CanCreateNewWindow = $true
        WindowsTerminalAvailable = $false
        VSCodeTerminal = $false
    }
    try {
        # Detect terminal type based on environment variables and process information
        $parentProcess = $null
        $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($currentProcess -and $currentProcess.Parent) {
            $parentProcess = Get-Process -Id $currentProcess.Parent.Id -ErrorAction SilentlyContinue
        }
        # Check for Windows Terminal
        if ($env:WT_SESSION -or $env:WT_PROFILE_ID) {
            $capabilities.TerminalType = "WindowsTerminal"
            $capabilities.SupportsSplitWindow = $true
            $capabilities.WindowsTerminalAvailable = $true
        }
        # Check for VS Code terminal
        elseif ($env:TERM_PROGRAM -eq "vscode" -or $env:VSCODE_PID) {
            $capabilities.TerminalType = "VSCode"
            $capabilities.SupportsSplitWindow = $true
            $capabilities.VSCodeTerminal = $true
        }
        # Check for PowerShell ISE
        elseif ($psISE) {
            $capabilities.TerminalType = "PowerShellISE"
            $capabilities.SupportsInteractiveInput = $false
            $capabilities.SupportsSplitWindow = $false
        }
        # Check for Windows PowerShell Console Host
        elseif ($Host.Name -eq "ConsoleHost") {
            if ($parentProcess -and $parentProcess.ProcessName -eq "WindowsTerminal") {
                $capabilities.TerminalType = "WindowsTerminal"
                $capabilities.SupportsSplitWindow = $true
                $capabilities.WindowsTerminalAvailable = $true
            } elseif ($parentProcess -and $parentProcess.ProcessName -eq "Code") {
                $capabilities.TerminalType = "VSCode"
                $capabilities.SupportsSplitWindow = $true
                $capabilities.VSCodeTerminal = $true
            } else {
                $capabilities.TerminalType = "PowerShellConsole"
            }
        }
        # Check for PowerShell 7+ terminal
        elseif ($Host.Name -eq "ConsoleHost" -and $PSVersionTable.PSVersion.Major -ge 7) {
            $capabilities.TerminalType = "PowerShell7Console"
        }
        # Test for Windows Terminal availability even if not currently running in it
        if (-not $capabilities.WindowsTerminalAvailable) {
            try {
                $wtPath = Get-Command "wt" -ErrorAction SilentlyContinue
                if ($wtPath) {
                    $capabilities.WindowsTerminalAvailable = $true
                }
            } catch {
                # Windows Terminal not available
            }
        }
        # Test color support
        try {
            $capabilities.SupportsColors = $Host.UI.SupportsVirtualTerminal -or
                                         ($env:TERM -and $env:TERM -ne "dumb") -or
                                         ($capabilities.TerminalType -in @("WindowsTerminal", "VSCode", "PowerShellConsole"))
        } catch {
            $capabilities.SupportsColors = $true  # Assume support by default
        }
        # Test interactive input support
        try {
            $capabilities.SupportsInteractiveInput = $Host.UI.RawUI -and
                                                    $capabilities.TerminalType -ne "PowerShellISE"
        } catch {
            $capabilities.SupportsInteractiveInput = $true  # Assume support by default
        }
        # Test toast notification support
        try {
            $capabilities.SupportsToastNotifications = [System.Environment]::OSVersion.Platform -eq "Win32NT" -and
                                                      [System.Environment]::OSVersion.Version.Major -ge 10
        } catch {
            $capabilities.SupportsToastNotifications = $true  # Assume support by default
        }
    } catch {
        Write-Verbose "Error detecting terminal capabilities: $($_.Exception.Message)"
        # Return safe defaults on error
    }
    return $capabilities
}
function Test-SplitWindowSupport {
    <#
    .SYNOPSIS
    Test if the current terminal supports split window functionality
    .DESCRIPTION
    Checks if the current terminal environment supports creating split panes or windows
    .OUTPUTS
    Boolean indicating split window support
    #>
    $capabilities = Get-TerminalCapabilities
    return $capabilities.SupportsSplitWindow
}
function Get-WindowsTerminalPath {
    <#
    .SYNOPSIS
    Get the path to Windows Terminal executable
    .DESCRIPTION
    Attempts to locate the Windows Terminal executable in common locations
    .OUTPUTS
    String path to wt.exe or $null if not found
    #>
    try {
        # Try to find wt command
        $wtCommand = Get-Command "wt" -ErrorAction SilentlyContinue
        if ($wtCommand) {
            return $wtCommand.Source
        }
        # Try common installation paths
        $commonPaths = @(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe",
            "$env:ProgramFiles\WindowsApps\Microsoft.WindowsTerminal*\wt.exe",
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\wt.exe"
        )
        foreach ($path in $commonPaths) {
            $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
            if ($resolved) {
                return $resolved.Path
            }
        }
        return $null
    } catch {
        return $null
    }
}
function Show-TerminalCapabilities {
    <#
    .SYNOPSIS
    Display current terminal capabilities for debugging
    .DESCRIPTION
    Shows detailed information about the current terminal environment and its capabilities
    #>
    $capabilities = Get-TerminalCapabilities
    Write-Host "🖥️ Terminal Capabilities Report" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Terminal Type: " -NoNewline -ForegroundColor Yellow
    Write-Host $capabilities.TerminalType -ForegroundColor White
    Write-Host "Supports Colors: " -NoNewline -ForegroundColor Yellow
    $colorStatus = if ($capabilities.SupportsColors) { "✅ Yes" } else { "❌ No" }
    Write-Host $colorStatus -ForegroundColor $(if ($capabilities.SupportsColors) { "Green" } else { "Red" })
    Write-Host "Supports Interactive Input: " -NoNewline -ForegroundColor Yellow
    $interactiveStatus = if ($capabilities.SupportsInteractiveInput) { "✅ Yes" } else { "❌ No" }
    Write-Host $interactiveStatus -ForegroundColor $(if ($capabilities.SupportsInteractiveInput) { "Green" } else { "Red" })
    Write-Host "Supports Split Window: " -NoNewline -ForegroundColor Yellow
    $splitStatus = if ($capabilities.SupportsSplitWindow) { "✅ Yes" } else { "❌ No" }
    Write-Host $splitStatus -ForegroundColor $(if ($capabilities.SupportsSplitWindow) { "Green" } else { "Red" })
    Write-Host "Supports Toast Notifications: " -NoNewline -ForegroundColor Yellow
    $toastStatus = if ($capabilities.SupportsToastNotifications) { "✅ Yes" } else { "❌ No" }
    Write-Host $toastStatus -ForegroundColor $(if ($capabilities.SupportsToastNotifications) { "Green" } else { "Red" })
    Write-Host "Windows Terminal Available: " -NoNewline -ForegroundColor Yellow
    $wtStatus = if ($capabilities.WindowsTerminalAvailable) { "✅ Yes" } else { "❌ No" }
    Write-Host $wtStatus -ForegroundColor $(if ($capabilities.WindowsTerminalAvailable) { "Green" } else { "Red" })
    Write-Host "VS Code Terminal: " -NoNewline -ForegroundColor Yellow
    $vscodeStatus = if ($capabilities.VSCodeTerminal) { "✅ Yes" } else { "❌ No" }
    Write-Host $vscodeStatus -ForegroundColor $(if ($capabilities.VSCodeTerminal) { "Green" } else { "Red" })
    Write-Host ""
    Write-Host "Environment Details:" -ForegroundColor Yellow
    Write-Host "  PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host "  Host Name: $($Host.Name)" -ForegroundColor Gray
    Write-Host "  Process ID: $PID" -ForegroundColor Gray
    if ($env:WT_SESSION) {
        Write-Host "  Windows Terminal Session: $($env:WT_SESSION)" -ForegroundColor Gray
    }
    if ($env:WT_PROFILE_ID) {
        Write-Host "  Windows Terminal Profile: $($env:WT_PROFILE_ID)" -ForegroundColor Gray
    }
    if ($env:VSCODE_PID) {
        Write-Host "  VS Code Process ID: $($env:VSCODE_PID)" -ForegroundColor Gray
    }
    if ($env:TERM_PROGRAM) {
        Write-Host "  Terminal Program: $($env:TERM_PROGRAM)" -ForegroundColor Gray
    }
}
function Start-SpotifyCliInSidecar {
    <#
    .SYNOPSIS
    Launch Spotify CLI in a split window or sidecar
    .DESCRIPTION
    Attempts to launch the Spotify CLI in a split window or sidecar based on the current terminal capabilities.
    Falls back to a new window if split window is not supported.
    .PARAMETER ScriptPath
    Path to the spotifyCLI.ps1 script to launch
    .PARAMETER ForceNewWindow
    Force opening in a new window instead of attempting split window
    .PARAMETER SplitDirection
    Direction for split window (right, down, left, up). Only applies to Windows Terminal.
    .OUTPUTS
    Boolean indicating success of the launch operation
    #>
    param(
        [string]$ScriptPath = ".\spotifyCLI.ps1",
        [switch]$ForceNewWindow,
        [ValidateSet("right", "down", "left", "up")]
        [string]$SplitDirection = "right"
    )
    $capabilities = Get-TerminalCapabilities
    # Resolve the script path
    if (-not (Test-Path $ScriptPath)) {
        # Try to find the script in the current directory or module directory
        $possiblePaths = @(
            $ScriptPath,
            ".\spotifyCLI.ps1",
            "$PSScriptRoot\spotifyCLI.ps1",
            "$(Split-Path $PSScriptRoot)\spotifyCLI.ps1"
        )
        $foundPath = $null
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                $foundPath = Resolve-Path $path
                break
            }
        }
        if (-not $foundPath) {
            Write-Host "❌ Could not find spotifyCLI.ps1 script" -ForegroundColor Red
            Write-Host "💡 Please ensure the script is in the current directory or specify the full path" -ForegroundColor Yellow
            return $false
        }
        $ScriptPath = $foundPath.Path
    }
    # If force new window or split not supported, use new window
    if ($ForceNewWindow -or -not $capabilities.SupportsSplitWindow) {
        return Start-SpotifyCliInNewWindow -ScriptPath $ScriptPath
    }
    # Attempt split window based on terminal type
    switch ($capabilities.TerminalType) {
        "WindowsTerminal" {
            return Start-SpotifyCliInWindowsTerminalSplit -ScriptPath $ScriptPath -SplitDirection $SplitDirection
        }
        "VSCode" {
            return Start-SpotifyCliInVSCodeSplit -ScriptPath $ScriptPath
        }
        default {
            Write-Host "💡 Split window not supported in $($capabilities.TerminalType). Opening in new window..." -ForegroundColor Yellow
            return Start-SpotifyCliInNewWindow -ScriptPath $ScriptPath
        }
    }
}
function Start-SpotifyCliInWindowsTerminalSplit {
    <#
    .SYNOPSIS
    Launch Spotify CLI in Windows Terminal split pane
    .PARAMETER ScriptPath
    Path to the spotifyCLI.ps1 script
    .PARAMETER SplitDirection
    Direction for the split (right, down, left, up)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [string]$SplitDirection = "right"
    )
    try {
        $wtPath = Get-WindowsTerminalPath
        if (-not $wtPath) {
            Write-Host "❌ Windows Terminal not found" -ForegroundColor Red
            return $false
        }
        # Build Windows Terminal split command
        $splitArg = switch ($SplitDirection.ToLower()) {
            "right" { "--split-pane" }
            "down" { "--split-pane", "--vertical" }
            "left" { "--split-pane", "--horizontal" }
            "up" { "--split-pane", "--vertical" }
            default { "--split-pane" }
        }
        # Create the command arguments
        $arguments = @($splitArg) + @("--profile", "PowerShell") + @("powershell", "-NoExit", "-Command", "& '$ScriptPath'")
        Write-Host "🪟 Opening Spotify CLI in Windows Terminal split pane..." -ForegroundColor Cyan
        Start-Process -FilePath $wtPath -ArgumentList $arguments -ErrorAction Stop
        Write-Host "✅ Spotify CLI launched in split pane" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "❌ Failed to open Windows Terminal split: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Falling back to new window..." -ForegroundColor Yellow
        return Start-SpotifyCliInNewWindow -ScriptPath $ScriptPath
    }
}
function Start-SpotifyCliInVSCodeSplit {
    <#
    .SYNOPSIS
    Launch Spotify CLI in VS Code terminal split
    .PARAMETER ScriptPath
    Path to the spotifyCLI.ps1 script
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )
    try {
        # VS Code terminal splitting requires the VS Code command palette or extension
        # For now, provide user guidance and fall back to new terminal
        Write-Host "💡 VS Code Terminal Split Instructions:" -ForegroundColor Cyan
        Write-Host "   1. Press Ctrl+Shift+5 to split the terminal" -ForegroundColor Gray
        Write-Host "   2. In the new terminal pane, run: & '$ScriptPath'" -ForegroundColor Gray
        Write-Host "   3. Or use the Terminal menu > Split Terminal" -ForegroundColor Gray
        Write-Host ""
        Write-Host "🔄 Alternatively, opening in new VS Code terminal..." -ForegroundColor Yellow
        # Try to open a new terminal in VS Code
        # This uses the integrated terminal API if available
        if ($env:VSCODE_PID) {
            # Create a new terminal and run the script
            $command = "& '$ScriptPath'"
            Start-Process -FilePath "powershell" -ArgumentList "-NoExit", "-Command", $command -ErrorAction Stop
            Write-Host "✅ Spotify CLI launched in new terminal" -ForegroundColor Green
            return $true
        } else {
            return Start-SpotifyCliInNewWindow -ScriptPath $ScriptPath
        }
    } catch {
        Write-Host "❌ Failed to open VS Code terminal: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Falling back to new window..." -ForegroundColor Yellow
        return Start-SpotifyCliInNewWindow -ScriptPath $ScriptPath
    }
}
function Start-SpotifyCliInNewWindow {
    <#
    .SYNOPSIS
    Launch Spotify CLI in a new window
    .PARAMETER ScriptPath
    Path to the spotifyCLI.ps1 script
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )
    try {
        Write-Host "🪟 Opening Spotify CLI in new window..." -ForegroundColor Cyan
        # Determine the best PowerShell executable to use
        $psExecutable = if ($PSVersionTable.PSVersion.Major -ge 7) {
            "pwsh"
        } else {
            "powershell"
        }
        # Try to use the same PowerShell version as current session
        try {
            $currentPSPath = (Get-Process -Id $PID).Path
            if ($currentPSPath -and (Test-Path $currentPSPath)) {
                $psExecutable = $currentPSPath
            }
        } catch {
            # Fall back to default
        }
        $arguments = @("-NoExit", "-Command", "& '$ScriptPath'")
        Start-Process -FilePath $psExecutable -ArgumentList $arguments -ErrorAction Stop
        Write-Host "✅ Spotify CLI launched in new window" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "❌ Failed to open new window: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "💡 Try running the script manually: & '$ScriptPath'" -ForegroundColor Yellow
        return $false
    }
}
function Test-SidecarLaunch {
    <#
    .SYNOPSIS
    Test sidecar launching functionality
    .DESCRIPTION
    Tests the sidecar launching functionality without actually launching the CLI
    #>
    Write-Host "🧪 Testing Sidecar Launch Functionality" -ForegroundColor Cyan
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host ""
    $capabilities = Get-TerminalCapabilities
    Write-Host "Current Terminal: $($capabilities.TerminalType)" -ForegroundColor Yellow
    Write-Host "Split Window Support: $(if ($capabilities.SupportsSplitWindow) { '✅ Yes' } else { '❌ No' })" -ForegroundColor $(if ($capabilities.SupportsSplitWindow) { "Green" } else { "Red" })
    Write-Host ""
    # Test script path detection
    $scriptPaths = @(
        ".\spotifyCLI.ps1",
        "$PSScriptRoot\spotifyCLI.ps1",
        "$(Split-Path $PSScriptRoot)\spotifyCLI.ps1"
    )
    $foundScript = $false
    foreach ($path in $scriptPaths) {
        if (Test-Path $path) {
            Write-Host "✅ Found script at: $path" -ForegroundColor Green
            $foundScript = $true
            break
        }
    }
    if (-not $foundScript) {
        Write-Host "⚠️ spotifyCLI.ps1 script not found in expected locations" -ForegroundColor Yellow
        Write-Host "   Checked paths:" -ForegroundColor Gray
        foreach ($path in $scriptPaths) {
            Write-Host "   - $path" -ForegroundColor Gray
        }
    }
    # Test Windows Terminal availability
    if ($capabilities.WindowsTerminalAvailable) {
        $wtPath = Get-WindowsTerminalPath
        Write-Host "✅ Windows Terminal available at: $wtPath" -ForegroundColor Green
    } else {
        Write-Host "❌ Windows Terminal not available" -ForegroundColor Red
    }
    # Provide recommendations
    Write-Host ""
    Write-Host "Recommendations:" -ForegroundColor Yellow
    if ($capabilities.SupportsSplitWindow) {
        switch ($capabilities.TerminalType) {
            "WindowsTerminal" {
                Write-Host "  ✅ Use Start-SpotifyCliInSidecar for Windows Terminal split pane" -ForegroundColor Green
            }
            "VSCode" {
                Write-Host "  ✅ Use Start-SpotifyCliInSidecar for VS Code terminal integration" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  💡 Use Start-SpotifyCliInSidecar -ForceNewWindow for new window launch" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Test completed successfully!" -ForegroundColor Green
}
# End Window Management Section
# Initialize custom aliases when module loads
Initialize-SpotifyAliases
# Export functions and aliases
# First export removed - using consolidated export below
#
# Installation and Maintenance Functions Section
# Import installation system functions if available
$installationScripts = @(
    "Install-SpotifyCliDependencies.ps1",
    "Test-SpotifyCliInstallation.ps1",
    "Uninstall-SpotifyCli.ps1"
)
foreach ($script in $installationScripts) {
    $scriptPath = Join-Path $PSScriptRoot $script
    if (Test-Path $scriptPath) {
        try {
            . $scriptPath
        } catch {
            Write-Verbose "Could not load installation script: $script"
        }
    }
}
# End Alias Initialization Section
# Export Module Members Section
# Export all functions for global access
Export-ModuleMember -Function @(
    # Core playback functions
    'Show-SpotifyTrack', 'Show-CurrentTrack', 'Start-SpotifyApp', 'spotify-now',
    'play', 'pause', 'next', 'previous',
    # Advanced controls
    'volume', 'seek', 'shuffle', 'repeat',
    # Podcast-specific controls
    'skip-forward', 'skip-back', 'replay',
    # Device management
    'devices', 'transfer',
    # Search and queue functions
    'search', 'search-albums', 'queue', 'play-album', 'queue-album',
    'Show-SpotifyQueue', 'Clear-SpotifyQueue', 'Remove-SpotifyQueueTrack', 'Add-SpotifyQueueTrack',
    # Library management
    'playlists', 'play-playlist', 'queue-playlist', 'liked', 'recent', 'save-track', 'unsave-track',
    # Interactive navigation
    'Start-InteractiveMode', 'Format-InteractiveItem', 'Test-InteractiveNavigation',
    # Enhanced functions
    'Show-Playlists', 'Start-PlaylistPlayback', 'Search-Albums', 'Start-AlbumPlayback', 
    'Show-GlobalNotification', 'Get-TerminalCapabilities',
    # Helper functions for testing and internal use
    'Format-Time', 'Show-ProgressBar', 'Get-StoredTokens', 'Set-StoredTokens',
    'Invoke-SpotifyApi', 'Get-TrackColor', 'Get-ArtistColor', 'Get-AlbumColor',
    'Get-ProgressColor', 'Get-StatusColor', 'Initialize-TokenStore',
    # Installation and maintenance functions
    'Install-SpotifyCliDependencies', 'Test-SpotifyCliInstallation',
    'Uninstall-SpotifyCli', 'Setup-SpotifyCredentials',
    'Get-SpotifyCliTroubleshootingGuide', 'Repair-SpotifyCliInstallation',
    # Configuration and help functions
    'Get-SpotifyConfig', 'Set-SpotifyConfig', 'Get-SpotifyHelp', 'spotify-help',
    'Test-SpotifyAuth', 'Get-SpotifyAliases',
    # Alias management
    'Set-SpotifyAlias', 'Remove-SpotifyAlias', 'Test-AliasConflicts',
    # Notifications
    'notifications', 'Show-TrackNotification', 'Test-NotificationSupport',
    # Window Management and Terminal Detection
    'Test-SplitWindowSupport', 'Get-WindowsTerminalPath', 'Show-TerminalCapabilities',
    # Sidecar and Split Window Launching
    'Start-SpotifyCliInSidecar', 'Start-SpotifyCliInWindowsTerminalSplit', 'Start-SpotifyCliInVSCodeSplit',
    'Start-SpotifyCliInNewWindow', 'Test-SidecarLaunch',
    # Default aliases as functions
    'sp', 'spotify', 'vol', 'sh', 'rep', 'tr', 'q', 'pl'
)
# Create aliases
New-Alias -Name 'spotify' -Value 'Start-SpotifyApp' -Force
New-Alias -Name 'plays-now' -Value 'Show-SpotifyTrack' -Force
New-Alias -Name 'music' -Value 'Show-SpotifyTrack' -Force
New-Alias -Name 'pn' -Value 'Show-SpotifyTrack' -Force
# Remove existing sp alias if it exists and create new one
if (Get-Alias -Name 'sp' -ErrorAction SilentlyContinue) {
    Remove-Item -Path 'Alias:\sp' -Force -ErrorAction SilentlyContinue
}
New-Alias -Name 'sp' -Value 'Show-SpotifyTrack' -Force
New-Alias -Name 'vol' -Value 'volume' -Force
New-Alias -Name 'sh' -Value 'shuffle' -Force
New-Alias -Name 'rep' -Value 'repeat' -Force
New-Alias -Name 'tr' -Value 'transfer' -Force
New-Alias -Name 'q' -Value 'queue' -Force
New-Alias -Name 'pl' -Value 'playlists' -Force
New-Alias -Name 'help' -Value 'Get-SpotifyHelp' -Force
# Export aliases for backward compatibility and ease of use
Export-ModuleMember -Alias @(
    'spotify', 'music', 'plays-now', 'pn', 'sp',
    'vol', 'sh', 'rep', 'tr', 'q', 'pl', 'help'
)
# End Export Module Members Section
