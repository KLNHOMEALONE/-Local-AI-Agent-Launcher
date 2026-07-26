Clear-Host
$ErrorActionPreference = "Stop"

# --- [ SYSTEM PATHS CONFIGURATION ] ---
$MODELS_DIR  = "C:\Models"
$PROJECTS_DIR = "D:\Projects"
$LLAMA_DIR    = "C:\LocalAI\llama.cpp"

# --- 1. CLEAN EXISTING INSTANCES & PROCESSES ---
Write-Host ">>> Flushing background architecture and resetting VRAM..." -ForegroundColor Red
Stop-Process -Name "llama-server" -Force -ErrorAction SilentlyContinue

# Безопасная очистка кэша (блокировки процессов не вызывают сбой скрипта)
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\opencode" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\claude-code" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\pi-code" -ErrorAction SilentlyContinue

# Ensure the slot cache directory exists safely on local disk
$SlotCacheDir = "C:\LocalAI\slot_cache"
if (!(Test-Path $SlotCacheDir)) { New-Item -ItemType Directory -Path $SlotCacheDir -Force | Out-Null }

# --- 2. INTERACTIVE MODEL SELECTION ---
$ModelFiles = Get-ChildItem -Path $MODELS_DIR -Filter "*.gguf" -ErrorAction SilentlyContinue
if ($ModelFiles.Count -eq 0) { Write-Error "Error: No .gguf models discovered inside $MODELS_DIR" }
Write-Host ""
Write-Host "=== AVAILABLE MODELS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ModelFiles.Count; $i++) { Write-Host "  [$($i + 1)] $($ModelFiles[$i].Name)" -ForegroundColor Yellow }
$ModelSelection = Read-Host "`nSelect model index number"
$SelectedModelFile = $ModelFiles[[int]$ModelSelection - 1]
$ModelPath = $SelectedModelFile.FullName

# Контекст строго сохранен в оригинальном размере
$ContextSize = 131072

# --- 2.5 SMART ARCHITECTURE DETECTOR & PARAMETER BINDING ---
# ФИКС: Удалены дефисы из имён переменных. В PowerShell дефис означает вычитание ($Top - $p).
$Temperature = "0.0"
$TopP = "0.85" 
$TopK = "20"
$StopTokens = @()
$PreserveThinking = $false  

# Дополнительные штрафы против зацикливания инструментов (по умолчанию отключены)
$FrequencyPenalty = "0.0"
$PresencePenalty = "0.1"

$ModelNameLower = $SelectedModelFile.Name.ToLower()

if ($ModelNameLower -like "*gemma*") {
    $Temperature = "1.0"
    # ФИКС: Удалены висящие запятые и лишние кавычки
    $TopP = "0.95" 
    $TopK = "64"
    $StopTokens = @("<turn|>", "<turn|user>", "<turn|model>")
    Write-Host ">>> Gemma 4 architecture detected. Parameters calibrated." -ForegroundColor Green
} 
elseif ($ModelNameLower -like "*qwopus*") {
    $Temperature = "0.6"
    $TopP = "0.95" 
    $TopK = "64"           
    $FrequencyPenalty = "0.5"       
    $PresencePenalty = "0.4"        
    $StopTokens = @("<|im_end|>", "<|endoftext|>", "<|im_start|>")
    Write-Host ">>> Qwopus MoE Agent architecture detected. Anti-Loop constraints injected." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*ornith*" -or $ModelNameLower -like "*r1*" -or $ModelNameLower -like "*reasoning*") {
    $Temperature = "1.0"
    $TopP = "0.95" 
    $TopK = "-1" 
    $StopTokens = @("<|im_end|>", "<turn|>")
    $PreserveThinking = $true  
    Write-Host ">>> Deep Reasoning model detected (Ornith/R1). Native 'preserve_thinking' workflow enabled." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*qwen*") {
    $Temperature = "1.0"
    $TopP = "0.95" 
    $TopK = "20" 
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    $PreserveThinking = $true  
    Write-Host ">>> Deep Reasoning model detected (Qwen). Native 'preserve_thinking' workflow enabled." -ForegroundColor Magenta
}  
else {
    $Temperature = "0.0"
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    Write-Host ">>> Standard Causal architecture detected (Qwen family). Temperature set to 0.0 with ChatML stop tokens." -ForegroundColor Cyan
}

# --- 3. INTERACTIVE PROJECT WORKING DIRECTORY SELECTION ---
$ProjectDirs = Get-ChildItem -Path $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
if ($ProjectDirs.Count -eq 0) { Write-Error "Error: No project environments discovered inside $PROJECTS_DIR" }
Write-Host ""
Write-Host "=== TARGET WORKSPACE PROJECTS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ProjectDirs.Count; $i++) { Write-Host "  [$($i + 1)] $($ProjectDirs[$i].Name)" -ForegroundColor Yellow }
$ProjectSelection = Read-Host "`nSelect project index number"
$TargetProjectDir = $ProjectDirs[[int]$ProjectSelection - 1].FullName

# --- 4. DETACHED SERVER INITIALIZATION DIRECTLY ON PORT 8080 (WINDOW 1) ---
Write-Host "`n>>> Launching native OpenAI/Anthropic-compatible llama-server on port 8080..." -ForegroundColor Green
$ServerPath = (Get-ChildItem -Path $LLAMA_DIR -Recurse -Filter "llama-server.exe" | Select-Object -First 1).FullName

# Собираем базовые стабильные параметры массивом строк
# ФИКС: Переменные изменены на новые имена без дефисов ($TopP и $TopK)
$ServerArgs = @(
    "-m", "$ModelPath", 
    "--host", "0.0.0.0", 
    "--port", "8080", 
    "-ngl", "99", 
    "-sm", "layer", 
    "--flash-attn", "on", 
    "--ctx-size", "$ContextSize", 
    "-ctk", "q4_0", 
    "-ctv", "q4_0", 
    "--no-mmap", 
    "-b", "1024",                    
    "-ub", "512",                    
    "--threads", "8", 
    "-tb", "8", 
    "-np", "1", 
    "--temp", "$Temperature",        
    "--min-p", "0.05", 
    "--top-p", "$TopP", 
    "--top-k", "$TopK", 
    "--repeat-penalty", "1.12",       
    "--repeat-last-n", "0",          
    "--frequency-penalty", "$FrequencyPenalty", 
    "--presence-penalty", "$PresencePenalty",   
    "--special",    
    "--jinja",               
    "--pooling", "none", 
    "--slot-save-path", "$SlotCacheDir", 
    "--alias", "local_model"
)

# ФИКС: Исправлено экранирование JSON кавычек под Windows CLI
if ($PreserveThinking) {
    $ServerArgs += "--chat-template-kwargs"
    $ServerArgs += '{\"preserve_thinking\":true}'
}

foreach ($token in $StopTokens) {
    $ServerArgs += "--reverse-prompt"
    $ServerArgs += "$token"
}

# Системный нативный запуск Windows
Start-Process -FilePath "$ServerPath" -ArgumentList $ServerArgs -WindowStyle Normal

Write-Host ">>> Allocating architecture weights to VRAM. Waiting 12 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 12

# --- 5. TARGET INTERACTIVE INTERFACE INVOCATION (WINDOW 2) ---
Write-Host "`n>>> Initializing Pi Coding Agent environment in second separate window..." -ForegroundColor Green

# ФИКС: Адрес полностью восстановлен до http://127.0.0.1:8080 для предотвращения падения Pi-агента [1]
$FinalCommand = "`$env:NODE_OPTIONS='--no-warnings'; `$env:PI_API_BASE='http://127.0.0.1:8080'; `$env:PI_MODEL='local_model'; `$env:AI_FLAVOR='vanilla-json'; cd '$TargetProjectDir'; pi"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs
