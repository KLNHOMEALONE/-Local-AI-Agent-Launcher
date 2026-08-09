Clear-Host
$ErrorActionPreference = "Stop"

# --- [ SYSTEM PATHS CONFIGURATION ] ---
# TabbyAPI stores each model in its own subdirectory inside model-dir.
# One subdirectory per model. Download with: huggingface_hub (see download helper below).
#
# IMPORTANT: forward slashes only. Backslash paths get the drive letter eaten
# by TabbyAPI's argparser on Windows.
$MODELS_DIR   = "C:/ModelsExl3"
$PROJECTS_DIR = "D:/Projects"
$TABBY_DIR    = "C:/LocalAI/TabbyAPIServer"
$VENV_PYTHON  = "$TABBY_DIR/venv/Scripts/python.exe"
$CONFIG_FILE  = "$TABBY_DIR/config.yml"

# TabbyAPI defaults: 5000. We pin it explicitly so the health-poll URL is unambiguous.
$Port = 5000
# 128K is a SAFE pre-selection default: every model in $MODELS_DIR can run at this size.
# After model selection we may bump to 256K via $ModelContextMap (section 2.5) based on
# each model's actual KV footprint -- hybrid Qwen3.5 (3x linear + 1x full attention) is
# dramatically cheaper than dense attention. Q4 cache mode halves VRAM vs FP16 with
# negligible quality loss -- important on 2x 16 GB when running 30B+ class models.
$ContextSize = 131072
$CacheMode   = "Q4"
# gpu_split_auto: Exllamav3 balances layers across both 5060 Ti 16 GB. Manual split
# (e.g. --gpu-split 16,16) is supported but not recommended unless you know the model
# size and want to pin a specific card.

# --- 1. CLEAN EXISTING INSTANCES & PROCESSES ---
Write-Host ">>> Flushing TabbyAPI background processes and resetting VRAM..." -ForegroundColor Red

# TabbyAPI runs as `python.exe main.py`. Find any process whose command line points
# at our install dir and kill it. Doing this via CIM is robust against multiple
# instances (Stop-Process -Name python would also kill unrelated python scripts).
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$TABBY_DIR*main.py*" } |
    ForEach-Object {
        Write-Host "    killing PID $($_.ProcessId) ($($_.CommandLine.Substring(0, [Math]::Min(80, $_.CommandLine.Length)))...)" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1   # let port 5000 release

# --- 2. INTERACTIVE MODEL SELECTION ---
# TabbyAPI's model_dir is a *directory of model directories*. Each model lives in
# its own subfolder (the one that contains config.json + safetensors / exl3 files).
if (!(Test-Path $MODELS_DIR)) {
    Write-Host ">>> Creating $MODELS_DIR (no models yet -- populate it later with downloaded Exl3 models)" -ForegroundColor DarkYellow
    New-Item -ItemType Directory -Path $MODELS_DIR -Force | Out-Null
}

$ModelDirs = Get-ChildItem -Path $MODELS_DIR -Directory -ErrorAction SilentlyContinue
if ($ModelDirs.Count -eq 0) {
    Write-Host "" -ForegroundColor Red
    Write-Host ">>> No model subdirectories found in $MODELS_DIR" -ForegroundColor Red
    Write-Host ">>> Each Exl3 / FP16 / BF16 model must be in its own subfolder." -ForegroundColor Red
    Write-Host ">>> To download a model, use the venv python directly:" -ForegroundColor Red
    Write-Host ">>>     python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id=<hf-id>, local_dir=<target>, max_workers=4)'" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=== AVAILABLE MODELS (subdirectories of $MODELS_DIR) ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ModelDirs.Count; $i++) {
    $Marker = if ($ModelDirs[$i].Name -like "*mmproj*") { " [vision projector -- pick main model, not this]" } else { "" }
    Write-Host "  [$($i + 1)] $($ModelDirs[$i].Name)$Marker" -ForegroundColor Yellow
}

$ModelSelection = Read-Host "`nSelect model index number"
$SelectedModelIdx = [int]$ModelSelection - 1
$SelectedModel = $ModelDirs[$SelectedModelIdx]
$ModelName = $SelectedModel.Name

# Guard: don't let a vision projector be picked as the main model.
if ($ModelName -like "*mmproj*") {
    Write-Host ">>> Invalid selection: '$ModelName' is a vision projector, not a chat model." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Sanity check: model subdir must contain a config.json or weight files
$HasConfig = Test-Path (Join-Path $SelectedModel.FullName "config.json")
$HasWeights = (Get-ChildItem -Path $SelectedModel.FullName -Include "*.safetensors", "*.exl3", "*.gguf" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
if (-not $HasConfig -and -not $HasWeights) {
    Write-Host ">>> WARNING: '$ModelName' contains no config.json or weight files -- TabbyAPI will likely fail to load it." -ForegroundColor Yellow
}

# --- 2.5 ADAPTIVE CONTEXT SIZE PER MODEL ---
# Hybrid Qwen3.5 (3x linear + 1x full attention, repeating) only needs KV cache for the
# full-attention layers. At Q4, the Qwen3.5 MoE models (40 layers, 10 full, kv_h=2) use
# just ~1.25 GB at 256K -- leaving plenty of room on 2x 5060 Ti 16 GB for the model
# itself (17-20 GB EXL3). Qwopus3.6-27B (64 layers, 16 full, kv_h=4) needs ~4 GB at 256K,
# still comfortable. Gemma-4 (5 full + 25 sliding(1024)) stays at ~2.5 GB Q4 at 256K.
#
# Add new models here as you install them. The safe default (no entry) is 128K, which
# always fits but wastes the long-context capability on most hybrid models.
$ModelContextMap = @{
    "Kwaipilot_KAT-Coder-V2.5-Dev-EXL3-4bpw"        = 262144   # 256K -- 1.25 GB Q4 cache
    "Huihui-Qwen3.6-35B-A3B-abliterated-exl3-4.5bpw" = 262144   # 256K -- 1.25 GB Q4 cache
    "Ornith-1.0-35B-EXL3-4.0bpw"                     = 262144   # 256K -- 1.25 GB Q4 cache
    "Qwopus3.6-27B-v2-exl3-6.00bpw"                  = 196608   # 192K -- 4 GB Q4 cache, headroom for 6bpw weights
    "Gemma-4-26B-A4B-it-exl3-5.10bpw"                = 262144   # 256K -- 2.5 GB Q4 cache (sliding window 1024)
}
$AdaptiveContextSize = $ModelContextMap[$ModelName]
if ($AdaptiveContextSize) {
    Write-Host ">>> Adaptive context: $ModelName -> $AdaptiveContextSize tokens ($([math]::Round($AdaptiveContextSize/1024))K)" -ForegroundColor DarkGreen
    $ContextSize = $AdaptiveContextSize
} else {
    Write-Host ">>> No context hint for '$ModelName' -- keeping safe default $ContextSize tokens" -ForegroundColor DarkYellow
}

# --- 2.6 OPTIONAL CPU/RAM OFFLOAD FOR KV CACHE ---
# Exllamav3's paged cache allocator auto-spills KV cache to system RAM the moment the
# chosen $ContextSize no longer fits alongside the model in VRAM. No flag is needed --
# the spill is transparent. Performance cost when offload kicks in:
#   * Prompt processing (prefill): 5-10x slower for the offloaded portion (PCIe-bound)
#   * Token generation (decode):    30-50% slower if most of the cache lives in RAM
#   * First-token latency (TTFT):  5-10x higher on long prompts
#
# To INTENTIONALLY force aggressive RAM offload (e.g., running a 70B model on 32 GB
# VRAM and spilling everything else), set before launching:
#
#     $env:TABBYAPI_FORCE_RAM_OFFLOAD = "1"
#
# Then also add `chunk_size: 1024` under the `model:` section of config.yml -- smaller
# chunks mean more frequent VRAM<->RAM transfers (slower) but lower peak VRAM (more
# headroom for weights). Default chunk_size (2048) is fine for the 256K Q4 configs
# above; you only need to tune it for >32B models or 512K+ context.
$ForceRamOffload = $env:TABBYAPI_FORCE_RAM_OFFLOAD -eq "1"
if ($ForceRamOffload) {
    Write-Host ">>> TABBYAPI_FORCE_RAM_OFFLOAD=1 -- KV cache will spill to RAM aggressively" -ForegroundColor DarkYellow
    Write-Host "    Add 'chunk_size: 1024' under model: in config.yml for tighter chunks" -ForegroundColor DarkYellow
    Write-Host "    Expect 5-10x slower prompt processing, 30-50% slower generation" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host ">>> Selected model: $ModelName (context=$ContextSize, cache=$CacheMode)" -ForegroundColor Green

# --- 3. INTERACTIVE PROJECT WORKING DIRECTORY SELECTION ---
$ProjectDirs = Get-ChildItem -Path $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
if ($ProjectDirs.Count -eq 0) { Write-Error "Error: No project environments discovered inside $PROJECTS_DIR" }

Write-Host ""
Write-Host "=== TARGET WORKSPACE PROJECTS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ProjectDirs.Count; $i++) {
    Write-Host "  [$($i + 1)] $($ProjectDirs[$i].Name)" -ForegroundColor Yellow
}

$ProjectSelection = Read-Host "`nSelect project index number"
$TargetProjectDir = $ProjectDirs[[int]$ProjectSelection - 1].FullName

# --- 4. INJECT SELECTED MODEL INTO config.yml ---
# We use config.yml for static settings (disable_auth, model_dir) and override
# model_name AND cache_size via in-place edits. The CLI args alone are unreliable
# when config.yml is loaded (the merger keeps the config's values), so we update
# config.yml in-place.
#
# cache_size MUST match the adaptive $ContextSize (262144 for KAT-Coder / Huihui /
# Ornith / Gemma-4, 196608 for Qwopus) -- otherwise TabbyAPI silently caps the
# actual KV cache at the stale 131072 from config.yml and rejects prompts with
# "Initial job allocation requires N cache tokens, which exceeds the available
# context size of 131072 tokens" even when --max-seq-len 262144 is passed.
#
# Three-step write so the launcher is robust to linters / manual edits that move
# the model_name / cache_size lines out of the `model:` block (which makes TabbyAPI
# silently skip model loading on startup, breaking chat with 500 / "Connection error"):
#   1. Strip ANY existing `model_name:` line, no matter how indented or where
#   2. Strip ANY existing `cache_size:` line (so the adaptive value wins)
#   3. Insert a fresh `  model_name: ...` and `  cache_size: $ContextSize` (2-space
#      indent) right after `model_dir:`
# Step 3 always lands inside the `model:` block, restoring correct YAML structure.
if (!(Test-Path $CONFIG_FILE)) {
    Write-Host ">>> ERROR: $CONFIG_FILE not found. Aborting." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$ConfigText = Get-Content -Path $CONFIG_FILE -Raw
# 1. Remove every existing model_name: line (handles linter-moved or duplicate)
$ConfigText = [regex]::Replace(
    $ConfigText,
    '^[ \t]*model_name:.*\r?\n?',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# 2. Remove every existing cache_size: line -- so the adaptive $ContextSize below
# wins over the stale 131072 that ships in config.yml. Without this, TabbyAPI
# caps the KV cache at 131072 and rejects prompts over 128K with
# "context_length_exceeded" / "Initial job allocation requires N cache tokens".
$ConfigText = [regex]::Replace(
    $ConfigText,
    '^[ \t]*cache_size:.*\r?\n?',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# 3. Insert model_name and cache_size immediately after model_dir:
$ConfigText = [regex]::Replace(
    $ConfigText,
    '(^[ \t]*model_dir:[^\r\n]*\r?\n)',
    "`$1  model_name: $ModelName`r`n  cache_size: $ContextSize`r`n",
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# Write WITHOUT UTF-8 BOM. Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
# adds a BOM by default, which breaks JSON parsers and the launcher script itself.
# UTF8Encoding($false) writes raw UTF-8 bytes with no BOM.
[System.IO.File]::WriteAllText($CONFIG_FILE, $ConfigText, (New-Object System.Text.UTF8Encoding $false))

# --- 5. TABBYAPI SERVER ARGUMENT BUILDER ---
# config.yml supplies: host=0.0.0.0, port=5000, disable_auth=true, model_dir,
# model_name (just rewritten above), cache_size (just rewritten above). CLI
# overrides below are for runtime tuning.
$TabbyArgs = @(
    "--config", "$CONFIG_FILE",
    "--max-seq-len", "$ContextSize",
    "--cache-mode", "$CacheMode",
    "--gpu-split-auto", "true"
)

Write-Host ""
Write-Host ">>> Launching TabbyAPI (Exllamav3 backend) on port $Port..." -ForegroundColor Green
Write-Host "    python main.py $($TabbyArgs -join ' ')" -ForegroundColor DarkCyan
Write-Host "    context=$ContextSize  kv_cache=$CacheMode  gpu_split=auto (2x RTX 5060 Ti)" -ForegroundColor DarkCyan

# --- 6. DETACHED SERVER INITIALIZATION ---
Write-Host ">>> Launching TabbyAPI (server console stays visible for live metrics)..." -ForegroundColor Green
# Start-Process -ArgumentList wants a single string array. The first element is
# the script path, the rest are CLI args. Combining into one @() avoids the
# "Cannot convert System.Object[] to System.String" error you'd get from
# passing ("main.py", $TabbyArgs) directly.
#
# WindowStyle Normal (default) so loguru's RICH_CONSOLE.print sink writes
# colored output -- including the Metrics line with prompt/generate T/s and
# context -- straight into the python.exe window. The user sees live metrics
# the same way llama.cpp's window did. Closing this launcher does not stop
# the python process; closing the python window does stop it.
$ProcessArgs = @("main.py") + $TabbyArgs
$ServerProc = Start-Process -FilePath "$VENV_PYTHON" `
                             -ArgumentList $ProcessArgs `
                             -WorkingDirectory "$TABBY_DIR" `
                             -WindowStyle Normal -PassThru

# --- 7. STARTUP READINESS POLL ---
# First load of a new model builds the EXL3 cache (~30-60s on RTX 5060 Ti for 19GB).
# Subsequent loads read the prebuilt cache from disk in 5-10s. Generous timeout.
$TimeoutSec = 240
$HealthUrl  = "http://127.0.0.1:$Port/health"
$Ready  = $false
$Waited = 0
Write-Host ">>> Waiting for $HealthUrl endpoint (up to $TimeoutSec s; first load builds EXL3 cache)..." -ForegroundColor Yellow

while ($Waited -lt $TimeoutSec) {
    Start-Sleep -Seconds 2
    $Waited += 2
    $ServerProc.Refresh()

    if ($ServerProc.HasExited) {
        Write-Host "`n>>> TABBYAPI CRASHED on startup. Exit code: $($ServerProc.ExitCode)" -ForegroundColor Red
        Write-Host ">>> Check the launched console window for the actual error (torch / CUDA / model)." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    try {
        $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            $Ready = $true
            break
        }
    } catch { }
}

if (-not $Ready) {
    Write-Host "`n>>> TabbyAPI did not become ready in $TimeoutSec seconds." -ForegroundColor Red
    if (-not $ServerProc.HasExited) {
        try { $ServerProc.Kill() } catch {}
    }
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ">>> TabbyAPI is ready after $Waited s on port $Port." -ForegroundColor Green

# --- 7.5 PRINT API INFO ---
Write-Host ""
Write-Host ">>> API endpoints (use these from your client):" -ForegroundColor Cyan
Write-Host "    Base URL  : http://127.0.0.1:$Port/v1" -ForegroundColor White
Write-Host "    Model     : $ModelName" -ForegroundColor White
Write-Host "    Health    : $HealthUrl" -ForegroundColor White
Write-Host "    Models    : http://127.0.0.1:$Port/v1/models" -ForegroundColor White

# --- 7.6 VRAM SANITY CHECK ---
Write-Host ""
Write-Host ">>> GPU telemetry after model load:" -ForegroundColor DarkCyan
try {
    & nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv 2>$null
} catch {
    Write-Host ">>> (nvidia-smi unavailable; skip)" -ForegroundColor DarkYellow
}

# --- 7.7 GLOBAL SYSTEM-PROMPT (central, no per-project copy) ---
# Pi natively supports: --append-system-prompt <text|file>
# (appends file CONTENTS to Pi's base system prompt). We reuse the same global file
# the llama.cpp launcher references so behavior is identical regardless of backend.
$GlobalAgentsFile = "$env:USERPROFILE/.pi/agent/AGENTS.md"

$AppendPromptArg = ""
if (Test-Path $GlobalAgentsFile) {
    $AppendPromptArg = " --append-system-prompt '$GlobalAgentsFile'"
    Write-Host ">>> Global system prompt guaranteed via --append-system-prompt: $GlobalAgentsFile" -ForegroundColor Green
} else {
    Write-Host ">>> WARNING: global instructions file not found: $GlobalAgentsFile" -ForegroundColor Red
}

# --- 8. SWITCH PI TO THIS BACKEND ---
# Pi reads its config from ~/.pi/agent/settings.json (defaultProvider/defaultModel)
# and ~/.pi/agent/models.json (provider baseUrl, api key, model list). It does NOT
# read PI_API_BASE / PI_MODEL env vars -- those are session markers Pi sets for
# child processes, not config inputs.
#
# If a Pi session is already running with a different defaultProvider, we kill it
# so the new settings take effect on next launch.
$PiSettingsPath = "$env:USERPROFILE/.pi/agent/settings.json"
if (Test-Path $PiSettingsPath) {
    Write-Host ">>> Switching Pi to TabbyAPI provider (model: $ModelName)..." -ForegroundColor Cyan

    # Kill any running Pi (node.exe with pi-coding-agent in its command line).
    # Multiple passes: a single Get-CimInstance can race with a node that's
    # still starting up and miss it. Two rounds + a final wait for the
    # Windows kernel to release the settings file handle.
    Write-Host "    killing any stale Pi node processes..." -ForegroundColor DarkYellow
    for ($round = 1; $round -le 2; $round++) {
        $Killed = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*pi-coding-agent*" } |
            ForEach-Object {
                Write-Host "      [round $round] killing Pi PID $($_.ProcessId)" -ForegroundColor DarkYellow
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        Start-Sleep -Seconds 1
    }
    if (-not $Killed) { Write-Host "    (no running Pi to kill)" -ForegroundColor DarkGray }
    Start-Sleep -Seconds 2   # let kernel release the settings.json file handle

    # Patch settings.json: switch provider to tabbyapi + set the selected model
    $PiSettings = Get-Content $PiSettingsPath -Raw | ConvertFrom-Json
    $PiSettings.defaultProvider = "tabbyapi"
    $PiSettings.defaultModel    = $ModelName
    # Write settings.json WITHOUT UTF-8 BOM (Set-Content -Encoding UTF8 adds BOM
    # on PowerShell 5.1, which breaks Pi's JSON parser). UTF8Encoding($false) =
    # raw UTF-8, no BOM.
    $PiSettings | ConvertTo-Json | ForEach-Object {
        [System.IO.File]::WriteAllText($PiSettingsPath, $_, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "    settings.json -> defaultProvider=tabbyapi, defaultModel=$ModelName" -ForegroundColor Green

    # Auto-register the selected model in models.json (tabbyapi provider).
    # Without this entry, Pi's model-resolver can't find $ModelName in the
    # provider's model list and silently falls back to the first available
    # model of the first provider with valid auth (usually lmstudio). So
    # any new model that lands in $MODELS_DIR is automatically exposed to
    # Pi on the next launcher run without a separate manual edit.
    $ModelsPath = "$env:USERPROFILE/.pi/agent/models.json"
    $ModelsData = @{ providers = @{ } }
    if (Test-Path $ModelsPath) {
        try {
            $existingModels = Get-Content $ModelsPath -Raw | ConvertFrom-Json
            if ($existingModels -and $existingModels.providers) {
                $ModelsData.providers = @{ }
                foreach ($pName in $existingModels.providers.PSObject.Properties.Name) {
                    $ModelsData.providers[$pName] = $existingModels.providers.$pName
                }
            }
        } catch {
            Write-Host "    (models.json unreadable, rewriting from scratch)" -ForegroundColor DarkYellow
        }
    }
    # Preserve existing tabbyapi config if present, otherwise seed defaults.
    $tabbyapiEntry = $ModelsData.providers["tabbyapi"]
    if (-not $tabbyapiEntry) {
        $tabbyapiEntry = [PSCustomObject]@{
            baseUrl  = "http://127.0.0.1:5000/v1"
            api      = "openai-completions"
            apiKey   = "no-auth-needed"
            compat   = [PSCustomObject]@{
                supportsDeveloperRole   = $false
                supportsReasoningEffort = $false
            }
            models   = @()
        }
    }
    # Ensure the models array contains the picked model; add it if missing.
    $hasModel = $false
    if ($tabbyapiEntry.models) {
        foreach ($m in $tabbyapiEntry.models) {
            if ($m.id -eq $ModelName) { $hasModel = $true; break }
        }
    }
    if (-not $hasModel) {
        # New entries default to text + image (multimodal Qwen3.5/3.6 models
        # support both). reasoning: true because all our installed models
        # are thinking models; user can override per-model by editing
        # models.json after the fact.
        #
        # contextWindow: TabbyAPI's /v1/models does NOT expose context length
        # (only id/object/created/owned_by/logging/parameters -- no max_context).
        # Without this field, Pi falls back to 128000 hardcoded in
        # extensions/llama/provider.js:15. We pass the (possibly adapted)
        # $ContextSize from section 2.5 so the status bar / compaction logic
        # see the real number.
        $newEntry = [PSCustomObject]@{
            id            = $ModelName
            name          = "$ModelName (TabbyAPI/EXL3)"
            input         = @("text", "image")
            reasoning     = $true
            contextWindow = $ContextSize
        }
        if ($tabbyapiEntry.models) {
            $tabbyapiEntry.models = @($tabbyapiEntry.models) + @($newEntry)
        } else {
            $tabbyapiEntry.models = @($newEntry)
        }
        $ModelsData.providers["tabbyapi"] = $tabbyapiEntry
        $ModelsData | ConvertTo-Json -Depth 10 | ForEach-Object {
            [System.IO.File]::WriteAllText($ModelsPath, $_, (New-Object System.Text.UTF8Encoding $false))
        }
        Write-Host "    models.json -> tabbyapi.models appended '$ModelName' (contextWindow=$ContextSize)" -ForegroundColor Green
    } else {
        # Backfill: existing entries (added by previous runs of this script
        # before the contextWindow field existed) lack contextWindow, so Pi
        # silently uses its 128000 hardcoded fallback. Update in-place if
        # the value differs from the adaptive $ContextSize.
        $updated = $false
        foreach ($m in @($tabbyapiEntry.models)) {
            if ($m.id -eq $ModelName -and ($m.PSObject.Properties['contextWindow'] -eq $null -or $m.contextWindow -ne $ContextSize)) {
                $m | Add-Member -NotePropertyName contextWindow -NotePropertyValue $ContextSize -Force
                $updated = $true
                Write-Host "    models.json -> backfilled contextWindow=$ContextSize on '$ModelName'" -ForegroundColor DarkGreen
                break
            }
        }
        if ($updated) {
            $ModelsData.providers["tabbyapi"] = $tabbyapiEntry
            $ModelsData | ConvertTo-Json -Depth 10 | ForEach-Object {
                [System.IO.File]::WriteAllText($ModelsPath, $_, (New-Object System.Text.UTF8Encoding $false))
            }
        }
    }

    # Patch auth.json: register tabbyapi as a configured provider. Pi's
    # model-resolver requires hasConfiguredAuth(provider) to return true
    # before honoring settings.json's defaultProvider. Without a stored
    # credential, resolveProviderAuth falls through to env-var lookup which
    # fails for the static "no-auth-needed" key in models.json -- so Pi
    # silently drops back to lmstudio/local-coder-model (the first provider
    # in models.json). Writing a stored api_key credential here makes the
    # auth check pass and keeps tabbyapi as the active provider.
    $AuthPath = "$env:USERPROFILE/.pi/agent/auth.json"
    $AuthData = @{}
    if (Test-Path $AuthPath) {
        try {
            $existing = Get-Content $AuthPath -Raw | ConvertFrom-Json
            if ($existing) {
                foreach ($prop in $existing.PSObject.Properties) {
                    $AuthData[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Host "    (auth.json unreadable, rewriting from scratch)" -ForegroundColor DarkYellow
        }
    }
    $AuthData["tabbyapi"] = @{
        type = "api_key"
        key  = "no-auth-needed"
    }
    $AuthData | ConvertTo-Json | ForEach-Object {
        [System.IO.File]::WriteAllText($AuthPath, $_, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "    auth.json -> tabbyapi registered as configured provider" -ForegroundColor Green
} else {
    Write-Host ">>> WARNING: $PiSettingsPath not found; Pi will not auto-switch providers." -ForegroundColor Yellow
}

# --- 9. TARGET INTERACTIVE INTERFACE INVOCATION (WINDOW 2) ---
Write-Host "`n>>> Initializing Pi Coding Agent environment in second separate window..." -ForegroundColor Green

# pi-hypa spawns the "hypa" native binary by default, but on Windows the binary
# lives at a local-to-pi path (C:\Users\KLN\.pi\agent\npm\node_modules\@hypabolic\
# hypa-win32-x64\bin\hypa.exe) that isn't on PATH. pi-hypa reads HYPA_BIN to
# resolve an absolute path; without it, child_process.spawn('hypa', ...) fails
# with EFTYPE ("inappropriate file type or format") and every hypa_find /
# hypa_ls / hypa_read / hypa_grep / hypa_shell call errors out. The npm wrapper
# bin.js resolves the right platform binary at runtime, so pointing HYPA_BIN at
# it is the safest option (handles linux/darwin/win32-arm64 automatically).
$HypaBin = "$env:USERPROFILE/.pi/agent/npm/node_modules/@hypabolic/hypa/bin.js"
if (Test-Path $HypaBin) {
    $HypaBinEnv = " `$env:HYPA_BIN='$HypaBin'"
    Write-Host ">>> HYPA_BIN pinned to: $HypaBin" -ForegroundColor Green
} else {
    $HypaBinEnv = ""
    Write-Host ">>> WARNING: hypa bin.js not found at $HypaBin -- hypa tools will fail with EFTYPE" -ForegroundColor Yellow
}

# Forward GITHUB_TOKEN from user-level env to the Pi process. Token is read at
# launcher run-time only -- never stored on disk by the launcher or in mcp.json.
# Set once via: [Environment]::SetEnvironmentVariable("GITHUB_TOKEN","ghp_xxx","User")
# Empty / unset -> github MCP server starts but auth fails; fetch/git/sequential-thinking
# still work.
$GitHubTokenEnv = ""
if ($env:GITHUB_TOKEN) {
    $GitHubTokenEnv = " `$env:GITHUB_TOKEN='$env:GITHUB_TOKEN'"
    Write-Host ">>> GITHUB_TOKEN forwarded from user env (length: $($env:GITHUB_TOKEN.Length))" -ForegroundColor Green
} else {
    Write-Host ">>> GITHUB_TOKEN not set in user env -- github MCP will fail to authenticate" -ForegroundColor Yellow
}

# Forward OBSIDIAN_API_KEY and OBSIDIAN_VAULT_PATH the same way. Both are
# required for the obsidian-mcp-server to reach the Local REST API plugin.
# Set once via: [Environment]::SetEnvironmentVariable("OBSIDIAN_API_KEY","...","User")
#              [Environment]::SetEnvironmentVariable("OBSIDIAN_VAULT_PATH","C:\path\to\vault","User")
$ObsidianEnv = ""
if ($env:OBSIDIAN_API_KEY -and $env:OBSIDIAN_VAULT_PATH) {
    # Note the trailing ';' on each -- PowerShell needs explicit statement
    # separators when multiple `$env:VAR=...` assignments are concatenated
    # into one -Command string. Without ';' PowerShell sees the two
    # assignments as a single malformed expression and throws
    # "Unexpected token '$env:OBSIDIAN_VAULT_PATH=...'".
    $ObsidianEnv = " `$env:OBSIDIAN_API_KEY='$env:OBSIDIAN_API_KEY';"
    $ObsidianEnv += " `$env:OBSIDIAN_VAULT_PATH='$env:OBSIDIAN_VAULT_PATH';"
    Write-Host ">>> OBSIDIAN_API_KEY + OBSIDIAN_VAULT_PATH forwarded (vault: $env:OBSIDIAN_VAULT_PATH)" -ForegroundColor Green
} else {
    Write-Host ">>> OBSIDIAN_API_KEY and/or OBSIDIAN_VAULT_PATH not set in user env -- obsidian MCP will not connect" -ForegroundColor Yellow
}

$FinalCommand = "`$env:NODE_OPTIONS='--no-warnings';$HypaBinEnv;$GitHubTokenEnv;$ObsidianEnv; cd '$TargetProjectDir'; pi$AppendPromptArg"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs

# --- 10. LIVE METRICS TAIL (one window -- matches run_local_ai_PI.ps1 UX) ---
# TabbyAPI's loguru handler writes to $TABBY_DIR/logs/. We tail it here in the
# LAUNCHER CONSOLE itself (one window, like the old llama.cpp launcher) AFTER
# Pi is launched so the tail is the final blocking stage. For each new line
# we classify: Metrics lines are parsed into a colored one-liner with prompt/
# generate T/s + context; Received/Finished are flagged; errors and warnings
# surface in red/yellow; INFO noise is dropped. A 30s background timer polls
# nvidia-smi and prints current VRAM/util so you can see the model's working
# state without opening another window.
$LogDir = "$TABBY_DIR/logs"
$LogFile = Get-ChildItem -Path $LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName

function Format-TabbyMetrics {
    param([string]$Line)
    $m = [regex]::Match($Line,
        'Metrics \(ID: ([0-9a-f]+)\): (\d+) tokens generated in ([\d.]+) seconds \(Queue: ([\d.]+) s, Process: (\d+) cached tokens and (\d+) new tokens at ([\d.]+) T/s, Generate: ([\d.]+) T/s, Context: (\d+) tokens\)')
    if (-not $m.Success) { return }
    $id     = $m.Groups[1].Value.Substring(0, 8)
    $tok    = [int]$m.Groups[2].Value
    $total  = [double]$m.Groups[3].Value
    $cached = [int]$m.Groups[5].Value
    $newTok = [int]$m.Groups[6].Value
    $procTs = [math]::Round([double]$m.Groups[7].Value, 1)
    $genTs  = [math]::Round([double]$m.Groups[8].Value, 1)
    $ctx    = [int]$m.Groups[9].Value

    $genColor  = if ($genTs -lt 5) { 'Red' } elseif ($genTs -lt 15) { 'Yellow' } else { 'Green' }
    $procColor = if ($procTs -lt 100) { 'Yellow' } else { 'Green' }
    # Context thresholds from config.yml: <12k OK, 12-20k warning, >20k red.
    $ctxColor  = if ($ctx -lt 12000) { 'Green' } elseif ($ctx -lt 20000) { 'Yellow' } else { 'Red' }

    Write-Host ("  -- [{0}] " -f $id) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,4} tok" -f $tok) -NoNewline -ForegroundColor White
    Write-Host (" in {0,5:N2}s " -f $total) -NoNewline -ForegroundColor DarkGray
    Write-Host "| ctx " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,5:N1}k" -f ($ctx/1000)) -NoNewline -ForegroundColor $ctxColor
    Write-Host (" ({0} cached, {1} new)" -f $cached, $newTok) -NoNewline -ForegroundColor DarkGray
    Write-Host " | prompt " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,7:N1}" -f $procTs) -NoNewline -ForegroundColor $procColor
    Write-Host " T/s | gen " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,5:N1}" -f $genTs) -NoNewline -ForegroundColor $genColor
    Write-Host " T/s" -ForegroundColor DarkGray
}

function Show-TabbyVram {
    $line = & nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>$null
    if ($line) {
        foreach ($row in $line) {
            $parts = $row -split ',\s*'
            if ($parts.Count -ge 4) {
                $pct = if ([int]$parts[2] -gt 0) { ($parts[1] / $parts[2] * 100) } else { 0 }
                Write-Host ("  [VRAM GPU{0}: {1}/{2} MB ({3:N1}%)  util {4}%]" -f $parts[0], $parts[1], $parts[2], $pct, $parts[3]) -ForegroundColor DarkCyan
            }
        }
    }
}

if ($LogFile) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host " LIVE METRICS TAIL: $LogFile" -ForegroundColor Cyan
    Write-Host " (Pi is in another window -- this console shows the server's view)" -ForegroundColor DarkCyan
    Write-Host " (Ctrl+C to stop tailing; the server keeps running)" -ForegroundColor DarkCyan
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host ""

    # Replay past Metrics lines from this log so you see recent activity on launch
    foreach ($line in (Get-Content $LogFile)) {
        if ($line -match 'Metrics \(ID:') { Format-TabbyMetrics $line }
    }
    Write-Host ""
    Write-Host "--- LIVE ---" -ForegroundColor Magenta
    Show-TabbyVram

    # 30s VRAM refresh
    $vramTimer = New-Object System.Timers.Timer
    $vramTimer.Interval = 30000
    $vramTimer.AutoReset = $true
    $vramTimer.add_Elapsed({ Show-TabbyVram })
    $vramTimer.Start()

    # Tail via FileStream -- reads new lines as they appear without polling.
    # If file was rotated/truncated, reopen from the new end.
    try {
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Position = $fs.Length
        $sr = New-Object System.IO.StreamReader($fs)

        while ($true) {
            $line = $sr.ReadLine()
            if ($line -eq $null) {
                Start-Sleep -Milliseconds 200
                if ($fs.Length -lt $fs.Position) { $fs.Position = $fs.Length }
                continue
            }
            if ($line -match 'Metrics \(ID:') {
                Format-TabbyMetrics $line
            }
            elseif ($line -match 'Received chat completion') {
                Write-Host ("  > request start: {0}" -f ($line.Split()[-1])) -ForegroundColor DarkYellow
            }
            elseif ($line -match 'Finished chat completion') {
                Write-Host ("  < request end:   {0}" -f ($line.Split()[-1])) -ForegroundColor DarkGreen
            }
            elseif ($line -match '\| ERROR    \|') {
                Write-Host $line -ForegroundColor Red
            }
            elseif ($line -match '\| WARNING  \|') {
                Write-Host $line -ForegroundColor Yellow
            }
        }
    }
    finally {
        $vramTimer.Stop(); $vramTimer.Dispose()
        if ($sr) { $sr.Close() }
        if ($fs) { $fs.Close() }
    }
} else {
    Write-Host ">>> WARNING: no log file found in $LogDir -- live viewer skipped" -ForegroundColor Yellow
}
