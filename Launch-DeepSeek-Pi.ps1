Clear-Host
$ErrorActionPreference = "Stop"

# --- STEP 2 FIX: Disable structured outputs globally to bypass the llama.cpp grammar parser bug
$env:PI_DISABLE_STRUCTURED_OUTPUT = "1"

# Force UTF-8 environment rendering to prevent encoding errors
[console]::InputEncoding = [System.Text.Encoding]::UTF8
[console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- [ SYSTEM PATHS CONFIGURATION ] ---
$PROJECTS_DIR = "D:\Projects"
$LLAMA_DIR    = "C:\LocalAI\llama.cpp"
$MODEL_PATH   = "C:\Models\UD-IQ2_M\DeepSeek-V4-Flash-0731-UD-IQ2_M-00001-of-00003.gguf"

# --- 1. GUARANTEED HARD PROCESS CLEANUP ---
Write-Host ">>> Force killing stale processes and clearing system memory..." -ForegroundColor Red
& cmd.exe /c "taskkill /F /T /IM llama-server.exe 2>nul" | Out-Null

$PiProcesses = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" 2>$null
foreach ($Proc in $PiProcesses) {
    if ($Proc.CommandLine -and $Proc.CommandLine -like "*pi-coding-agent*") {
        & cmd.exe /c "taskkill /F /T /PID $($Proc.ProcessId) 2>nul" | Out-Null
    }
}
Start-Sleep -Seconds 2

# Purge transient operational folders
$CachePaths = @("$env:USERPROFILE\.cache\opencode", "$env:USERPROFILE\.cache\claude-code", "$env:USERPROFILE\.cache\pi-code")
foreach ($Path in $CachePaths) {
    if (Test-Path $Path) { try { Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue } catch {} }
}

# --- 2. CONTEXT & PERFORMANCE OPTIMIZATIONS (64K BUFFER PIPELINE) ---
$ContextSize = 65536
$Temperature = "0.6"
$TopP = "0.95"
$TopK = "20"

# --- 3. INTERACTIVE WORKSPACE TARGET SELECTION ---
$ProjectDirs = Get-ChildItem -Path $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
if ($ProjectDirs.Count -eq 0) { Write-Error "Error: No project environments discovered inside $PROJECTS_DIR" }

Write-Host ""
Write-Host "=== TARGET WORKSPACE PROJECTS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ProjectDirs.Count; $i++) { 
    Write-Host "  [$($i + 1)] $($ProjectDirs[$i].Name)" -ForegroundColor Yellow 
}
$ProjectSelection = Read-Host "`nSelect project index number"
$TargetProjectDir = $ProjectDirs[[int]$ProjectSelection - 1].FullName

# --- 4. SERVER SEARCH AND ARGUMENT COMPILING ---
$ServerPath = (Get-ChildItem -Path $LLAMA_DIR -Recurse -Filter "llama-server.exe" | Select-Object -First 1).FullName
if ([string]::IsNullOrEmpty($ServerPath)) { Write-Error "llama-server.exe not found under directory path: $LLAMA_DIR" }

# --- STEP 1 FIX: Aggressive chunk batching array to scale layer-split performance to 12+ tokens/sec
$ServerArgs = @(
    "-m", $MODEL_PATH,
    "--host", "0.0.0.0",
    "--port", "8080",
    "-n", "-1",                 
    "--ctx-size", "65536",
    "-ctk", "q4_0",          
    "-ctv", "q4_0",          
    "-b", "4096",               # Boosts layer-split concurrency to fully saturate both GPUs
    "-ub", "1024",              # Expands execution block to prevent memory pipeline stalling
    "--threads", "14",       
    "-tb", "8",
    "-np", "1",                 
    "--temp", "0.6",
    "--min-p", "0.05",
    "--top-p", "0.95",
    "--top-k", "20",
    "--jinja",                  
    "--cont-batching",          
    "--alias", "local_model",
    "--flash-attn", "on",       
    "-ngl", "999",              
    "--split-mode", "layer",    # Keeps layout stable across dual cards to bypass the CUDA buffer crash
    "--n-cpu-moe", "99"         # Direct offloading constraint for MoE experts to your 96GB RAM
)

# --- 5. PATCH PI ROUTING SYSTEM FILES ---
$PiSettingsPath = "$env:USERPROFILE/.pi/agent/settings.json"
if (Test-Path $PiSettingsPath) {
    Write-Host "`n>>> Updating local provider configuration files for Pi..." -ForegroundColor Cyan
    $PiSettings = Get-Content $PiSettingsPath -Raw | ConvertFrom-Json
    $PiSettings.defaultProvider = "lmstudio"
    $PiSettings.defaultModel    = "local-coder-model"
    $PiSettings | ConvertTo-Json | ForEach-Object { [System.IO.File]::WriteAllText($PiSettingsPath, $_, (New-Object System.Text.UTF8Encoding $false)) }
}

# --- 6. BACKGROUND SERVER INITIALIZATION ---
Write-Host "`n>>> LAUNCHING NATIVE LLAMA-SERVER IN SEPARATE TERMINAL WINDOW..." -ForegroundColor Green
Write-Host "----------------------------------------------------------------"

$ServerProc = Start-Process -FilePath $ServerPath -ArgumentList $ServerArgs -WindowStyle Normal -PassThru

Write-Host ">>> Allocating RAM/VRAM split pipelines. Waiting 35s for DeepSeek weights to chain..." -ForegroundColor Yellow
Start-Sleep -Seconds 35

if ($ServerProc.HasExited) {
    Write-Host ">>> CRITICAL FAULT: Server crashed during runtime layer mapping!" -ForegroundColor Red
    exit 1
}

Write-Host ">>> Server engine holding execution contexts successfully!" -ForegroundColor Green

# --- 7. WORKSPACE TERMINAL CALL FOR PI ---
Write-Host "`n>>> Initializing Pi Coding Agent workspace..." -ForegroundColor Green

$HypaBin = "$env:USERPROFILE/.pi/agent/npm/node_modules/@hypabolic/hypa/bin.js"
$HypaBinEnv = if (Test-Path $HypaBin) { "`$env:HYPA_BIN='$HypaBin';" } else { "" }
$GitHubTokenEnv = if ($env:GITHUB_TOKEN) { "`$env:GITHUB_TOKEN='$env:GITHUB_TOKEN';" } else { "" }
$ObsidianEnv = if ($env:OBSIDIAN_API_KEY -and $env:OBSIDIAN_VAULT_PATH) { "`$env:OBSIDIAN_API_KEY='$env:OBSIDIAN_API_KEY';`$env:OBSIDIAN_VAULT_PATH='$env:OBSIDIAN_VAULT_PATH';" } else { "" }

# Enforces raw tool streaming context inside the spawned agent workspace window instance
$FinalCommand = "`$env:PI_DISABLE_STRUCTURED_OUTPUT='1'; `$env:NODE_OPTIONS='--no-warnings'; $HypaBinEnv $GitHubTokenEnv $ObsidianEnv Set-Location -LiteralPath '$TargetProjectDir'; pi"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs
