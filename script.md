# Local AI + Pi coding agent — setup & troubleshooting reference

Standalone stack (not part of this repo, kept here as reference): `llama-server` (llama.cpp)
serving a local GGUF on `:8080`, driven by the **Pi** coding agent.

- Launcher: `run_local_ai_PI.ps1` (in this folder; copy to `C:\LocalAI\`)
- Pi provider config: `%USERPROFILE%\.pi\agent\models.json`
- Global agent rules: `%USERPROFILE%\.pi\agent\AGENTS.md` (see `pi-AGENTS-rules.md`)
- Hardware this was tuned on: 2× RTX 5060Ti 16 GB = 32 GB VRAM, llama.cpp build b9848.

---

## Every bug we hit, and the fix

Ordered roughly as encountered. Most turned out to be **config/pipeline**, not the model.

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Server crashes instantly on launch | `--flash-attn on` — newer builds require the `on\|off\|auto` value, older builds are a valueless flag; wrong form aborts the parser | Probe `--help`, pass the form the binary supports |
| 2 | `--reverse-prompt` crash | It's a `llama-cli`-only flag; `llama-server` rejects unknown args | Removed. Stop tokens go in the per-request API body, not launch args |
| 3 | `<\|im_end\|>` / `<end_of_turn>` leaking into output; tool calls fail with "peg-native format" 500 | `--special` prints special tokens as literal text, corrupting tool-call boundary parsing | Removed `--special` |
| 4 | Bogus stop tokens (`<turn\|>` etc.) | Wrong token strings for Gemma/Ornith | Gemma → `<end_of_turn>`; Ornith/Qwen → `<\|im_end\|>`,`<\|endoftext\|>` |
| 5 | ornith/reasoning models crash at startup | `--chat-template-kwargs '{"preserve_thinking":true}'` unsupported on build b9848 | Use dedicated `--reasoning-preserve` (probe `--help`) |
| 6 | OOM at 128K context | `-ngl 99` forces all layers on GPU and aborts llama's auto-fit | Drop `-ngl` → let auto-fit spill layers to CPU for the big KV. Context 128K preserved |
| 7 | Output truncated ~128 tokens | Server default `n_predict` | `-n -1` (generate until context end) |
| 8 | **Tool-call paths/args truncated** (`aquarium.html` → `a`, `.../3`) | **Pi did not accumulate streaming tool-call `arguments` deltas** — llama.cpp streams the arg token-by-token; Pi took one fragment. (Server proven correct via non-stream probe.) | **`"stream": false`** in `models.json` provider block |
| 9 | Endless verbatim loops | `--repeat-last-n 0` DISABLES all penalties (window 0) | — but the real fix was DRY, see #10 |
| 10 | Word-salad (rare-word rambling) | Stacking `repeat`+`frequency`+`presence` penalties over-penalizes ordinary tokens | Token penalties OFF; **DRY sampler** as the sole anti-loop (penalizes repeated *sequences*, not tokens) |
| 11 | Filename typos (`aquarium`→`aquariun`→`aquarius`) | `--temp 1.0` (random char sampling) **+** DRY `allowed-length 4` penalizing the exact filename repeat from `ls` output | `--temp 0.6` (Qwen official) + DRY `allowed-length 8`, `multiplier 0.6` |
| 12 | Tool-call content truncated | `AI_FLAVOR='vanilla-json'` (undocumented) forced a broken text-parse path | Removed the env var; let Pi parse native OpenAI `tool_calls` |
| 13 | Global system prompt not guaranteed | Wanted one AGENTS.md across 100 projects without per-project copies | `pi --append-system-prompt %USERPROFILE%\.pi\agent\AGENTS.md` |

---

## Key lessons

- **Diagnose with probes, not guesses.** Direct `curl`/`Invoke-RestMethod` to `:8080` proved the
  server was fine (full tool_calls, 400+ tokens, correct streamed path) — which pinned the
  truncation on Pi's stream handling, not the model. The streaming probe (`stream:true`) vs
  non-streaming probe was the decisive test.
- **Run the server foreground to read stderr.** The launch window closes on crash; `& $srv @args`
  in the current terminal shows the real error (that's how flash-attn and reasoning-preserve
  were found — the server even printed "consider --reasoning-preserve").
- **Anti-loop: DRY, not token penalties.** Token-level `repeat/frequency/presence` penalties cause
  word-salad and corrupt strings the model must repeat verbatim (filenames, code). DRY penalizes
  repeated *sequences* and is the safe anti-loop — but keep `allowed-length` ≥ 8 so it doesn't
  mangle short legitimate repeats.
- **Temperature for agent/coder work: ~0.6, not 1.0.** High temp causes single-character typos in
  exact copies (paths, identifiers).
- **The model was mostly not the problem.** A dense Qwen 27B (Q4_K_XL) at temp 0.6 + `stream:false`
  + soft DRY is a solid local agent. Almost every failure was pipeline config.
- **Small MoE (e.g. A3B active) is genuinely weaker** at instruction-following and exact string
  copying — but confirm sampling config first; typos looked like model weakness but were temp+DRY.

---

## Reference: working configs

### `models.json` (`%USERPROFILE%\.pi\agent\`)
The `"stream": false` line is what fixed the tool-arg truncation.
```json
{
  "providers": {
    "lmstudio": {
      "baseUrl": "http://localhost:8080/v1",
      "api": "openai-completions",
      "apiKey": "lm-studio",
      "stream": false,
      "models": [
        { "id": "local-coder-model", "input": ["text"] }
      ]
    }
  }
}
```

### Launcher
See `run_local_ai_PI.ps1` in this folder — the authoritative, commented version.
Per-architecture sampling is auto-selected from the model filename (gemma / qwopus /
ornith|r1|reasoning / qwen / default).

### Global agent rules
See `pi-AGENTS-rules.md` — merge into `%USERPROFILE%\.pi\agent\AGENTS.md`. Covers: no guessing
filenames, full extensions, stop-the-loop after 2 failures, write large files in sections,
never use bash heredoc/python for file content, no duplicate-name files, no over-escaping.

---

## Diagnostic probes (delete when done)

- `pi-probe.ps1` — tool call with empty args (server sanity)
- `pi-probe-write.ps1` — tool call needing a long path+content arg (non-streaming)
- `pi-probe-nolimit.ps1` — no `max_tokens`, tests server default output cap
- `pi-probe-stream.ps1` — `stream:true`, proves whether streaming assembles args correctly
- `diag-ornith.ps1` — foreground server launch, bisects `--chat-template-kwargs`

To see why the server dies, run it foreground: `& $ServerPath @ServerArgs` (stderr stays visible).
