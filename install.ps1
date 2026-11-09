# Aura self-host installer for Windows (PowerShell).
#
# Generates the three required secrets (api_token, master_key, broker_token) into
# compose.yaml if they're still the CHANGE_ME placeholder, then starts the stack.
# Safe to re-run: if secrets are already set, it skips straight to `docker compose up -d`.
#
# Requirements: Docker Desktop, with PowerShell's execution policy allowing scripts
# (the one-liner below handles that for you - it never changes your system policy).
#
# Usage, in a normal (non-admin) PowerShell window:
#   mkdir aura; cd aura
#   irm https://raw.githubusercontent.com/ThePixelExpert/aura/main/install.ps1 | iex
#
# Or, if you already downloaded this file and have compose.yaml in the same folder:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'

$ComposeFile = 'compose.yaml'
$ComposeUrl = 'https://raw.githubusercontent.com/ThePixelExpert/aura/main/compose.yaml'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    # No "exit" here on purpose: when this script runs via `irm ... | iex` (not saved to a
    # file), `exit` closes the whole PowerShell window, not just this script. Write-Error
    # with $ErrorActionPreference = 'Stop' above already halts safely without doing that.
    Write-Error "docker is not installed or not on PATH. Install Docker Desktop first: https://www.docker.com/products/docker-desktop/"
}

if (-not (Test-Path $ComposeFile)) {
    Write-Host "No $ComposeFile here yet, fetching it..."
    Invoke-WebRequest -Uri $ComposeUrl -OutFile $ComposeFile
}

# RNGCryptoServiceProvider, not the newer RandomNumberGenerator.Fill() static method, on
# purpose: Fill() needs .NET 6+ (PowerShell 7 / pwsh.exe) and this script is meant to also
# run under the Windows PowerShell 5.1 (.NET Framework) that ships by default on Windows.
$script:Rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()

function New-HexSecret {
    $bytes = New-Object byte[] 32
    $script:Rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function New-MasterKey {
    $bytes = New-Object byte[] 32
    $script:Rng.GetBytes($bytes)
    $b64 = [Convert]::ToBase64String($bytes)
    $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

$content = Get-Content -Path $ComposeFile -Raw

if ($content.Contains('"CHANGE_ME"')) {
    Write-Host "First run: generating the three secrets..."
    $apiToken = New-HexSecret
    $brokerToken = New-HexSecret
    $masterKey = New-MasterKey

    $content = $content.Replace('api_token: &api_token "CHANGE_ME"', 'api_token: &api_token "' + $apiToken + '"')
    $content = $content.Replace('master_key: &master_key "CHANGE_ME"', 'master_key: &master_key "' + $masterKey + '"')
    $content = $content.Replace('broker_token: &broker_token "CHANGE_ME"', 'broker_token: &broker_token "' + $brokerToken + '"')
    Set-Content -Path $ComposeFile -Value $content -NoNewline

    if ((Get-Content -Path $ComposeFile -Raw).Contains('"CHANGE_ME"')) {
        Write-Error "Could not find the expected CHANGE_ME lines to replace - compose.yaml may have been edited. Open it and set api_token, master_key and broker_token by hand (see the comments at the top of the file)."
    }

    Write-Host ""
    Write-Host "=============================================================================="
    Write-Host " Secrets generated and written into $ComposeFile."
    Write-Host ""
    Write-Host " BACK UP this master_key now. It seals the credential files in the data"
    Write-Host " volume - lose it and anything already sealed with it cannot be read back."
    Write-Host ""
    Write-Host "   master_key: $masterKey"
    Write-Host "=============================================================================="
    Write-Host ""
} else {
    Write-Host "Secrets already set in $ComposeFile - skipping generation."
}

# ---- GPU auto-enable (only affects the optional local-models ollama service) --------------
# Ollama itself already splits a model's layers between GPU VRAM and system RAM/CPU on its
# own at runtime - there is nothing to configure for that "spill over" behaviour. The only
# manual step compose.yaml used to require was telling Docker it may hand the GPU to the
# container at all. If a usable NVIDIA GPU is detected, enable that automatically; otherwise
# leave it alone (CPU-only, which still works, just slower). AMD/Intel GPUs need a different
# Ollama image/device setup and are not auto-detected here - see the README if that's you.
$content = Get-Content -Path $ComposeFile -Raw

if ($content.Contains("    # deploy:")) {
    $gpuUsable = $false

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            & nvidia-smi -L *> $null
            if ($LASTEXITCODE -eq 0) {
                $dockerInfo = & docker info --format '{{json .Runtimes}}' 2>$null
                if ($dockerInfo -match '"nvidia"') {
                    $gpuUsable = $true
                }
            }
        } catch {
            $gpuUsable = $false
        }
    }

    if ($gpuUsable) {
        $content = $content.Replace("    # deploy:", "    deploy:")
        $content = $content.Replace("    #   resources:", "      resources:")
        $content = $content.Replace("    #     reservations:", "        reservations:")
        $content = $content.Replace("    #       devices:", "          devices:")
        $content = $content.Replace("    #         - driver: nvidia", "            - driver: nvidia")
        $content = $content.Replace("    #           count: all", "              count: all")
        $content = $content.Replace("    #           capabilities: [gpu]", "              capabilities: [gpu]")
        Set-Content -Path $ComposeFile -Value $content -NoNewline
        Write-Host "NVIDIA GPU detected and usable by Docker - enabled GPU acceleration for local models."
    } else {
        Write-Host "No usable NVIDIA GPU detected - local models (if you turn them on) will run on CPU."
        Write-Host "(Have an NVIDIA GPU but see this? Install the NVIDIA driver (it includes WSL2 GPU support)"
        Write-Host " and make sure Docker Desktop is set to use the WSL2 backend, then re-run this script.)"
    }
}

# The ollama/model-puller services are gated behind the "models" Compose profile and never
# start on a plain "docker compose up -d", even with AURA_HOSTED_ONLY set to "0" - that env
# var only controls what the *backend* does, Compose still needs --profile models to actually
# start the ollama container at all. Add it automatically so turning on AURA_HOSTED_ONLY "0"
# is the only thing anyone has to remember.
$composeArgs = @()
if ((Get-Content -Path $ComposeFile -Raw).Contains('AURA_HOSTED_ONLY: "0"')) {
    $composeArgs = @('--profile', 'models')
    Write-Host "Local models are on (AURA_HOSTED_ONLY: `"0`") - starting with --profile models so ollama actually comes up."
}

Write-Host "Starting Aura..."
docker compose @composeArgs up -d

Write-Host ""
Write-Host "Aura is starting. Open http://localhost:3010 (or whatever address you set via"
Write-Host "x-address in compose.yaml), then go to Settings -> AI Providers to add your key."
