\# CROSS-MODEL KNOWLEDGE REUSE RULES

ALWAYS call the read tool before claiming you cannot see a file. NEVER say you cannot read files.

\## 1. PRE-EXECUTION SEARCH (DO NOT INVENT THE WHEEL)

Before writing any code, implementing a new feature, or setting up an architectural pattern from scratch, you MUST:

1\. Scan the global directory: `\~/ai-shared-cookbook/recipes/`.

2\. Check if a blueprint for a similar feature (e.g., authentication, pagination, background tasks) already exists.

3\. If a relevant recipe is found, treat its "Architecture \& Concepts" and "Reference Implementation" sections as the absolute gold standard.

4\. Adapt this existing codebase to the current project's stack. Maintain consistent naming conventions, directory structures, and error handling as defined in the recipe—regardless of which model (Gemma, Qwen, Qwopus) generated it previously.



## 2. POST-EXECUTION PERSISTENCE
Once a new feature is successfully implemented, verified, and functioning, you should prompt the user to save it to the shared knowledge base. If approved:
1. Generate a clean, reusable blueprint following the standard recipe template.
2. Strip out project-specific variables, secrets, or unique business logic.
3. Save the file into `~/ai-shared-cookbook/recipes/` with a descriptive, lowercase, kebab-case filename (e.g., `fastapi-jwt-auth.md`).

## FILESYSTEM VISIBILITY RESTRICTIONS
1. NEVER read, parse, or traverse the following paths or patterns inside `~/ai-shared-cookbook/`:
   - `.obsidian/` (Internal Obsidian application state)
   - `*.json` (Workspace configurations and plugin data)
   - `.space/` (Canvas and workspace metadata)
2. If executing a recursive search or directory listing, programmatically exclude these patterns from your search parameters to save context window tokens.

# TOOL-USAGE DISCIPLINE (merge into ~/.pi/agent/AGENTS.md)

These rules fix small-model failure modes: guessing filenames, dropping extensions,
and re-trying the same broken tool call in a loop.

## FILE ACCESS RULES

1. NEVER guess a file path or filename. If you have not confirmed a file exists in
   THIS session, list the directory first with the `ls` (or `find`) tool and copy the
   exact name from the output.

2. ALWAYS include the full filename WITH its extension (e.g. `dino-game-fixed.html`,
   not `dino-game-fixed`). Never truncate, shorten, or strip the extension.

3. The read tool's line-range suffix uses `path:START-END` (e.g.
   `D:/Projects/App/index.html:1-50`). The part before `:` MUST be a complete, real
   path including extension.

## STOP-THE-LOOP RULES

4. If a tool call fails with `ENOENT` / "no such file or directory": DO NOT retry with
   a shortened or altered guess. Instead, immediately run `ls` on the parent directory,
   read the exact name from the result, then retry ONCE with that exact name.

5. NEVER repeat the same failing tool call more than twice. After two failures on the
   same operation, STOP and report to the user what you tried and what failed. Do not
   keep trying variations silently.

6. You CAN read files — you have the `read` tool. NEVER claim you "cannot read files".
   If you need a file's current contents, call `read` on its exact path.

## VERIFY-BEFORE-EDIT RULES

7. Before editing or overwriting a file, `read` it first to see its current contents.
   Do not overwrite based on assumptions about what the file contains.

8. After a write/edit, `read` the file back to confirm the change landed before
   claiming success.

## LARGE-FILE RULES

9. For files larger than ~200 lines: create the file once, then append/edit it in
   sections. NEVER regenerate a whole large file in a single write — large single
   writes get truncated by the output-token limit.

10. NEVER use bash heredoc (`cat > file << EOF`) or `python -c "..."` to write file
    content. That nests the content inside shell/Python string literals and the quote
    escaping breaks. Use the `write`/`edit` tools with raw content only (one layer).

## ONE-FILE / NO-DUPLICATE-NAMES RULES

11. Fix the EXISTING file in place with `edit`. NEVER create a new file with a variant
    name (`-fixed`, `-v2`, `-final`, `-new`, `-full`, `-copy`) to work around a problem.

12. If a previous write looks wrong or truncated, `read` the SAME file and correct it —
    do not start a fresh file under a different name.

13. Keep ONE canonical file per artifact. If you have already created `foo.html`, all
    further changes go into `foo.html`, never `foo-fixed.html`.

## QUOTE-ESCAPING RULES

14. Pass file content to the `write`/`edit` tool as-is: literal quotes, newlines, and
    backslashes go straight into the argument. Do NOT pre-escape them, do NOT wrap the
    content in extra quotes, and do NOT add `\"` or `\n` yourself — the tool takes raw
    text. Over-escaping corrupts the file (stray backslashes, doubled quotes).

15. NEVER route file content through a shell. No `echo "..."`, no `cat << EOF`, no
    `python -c "..."`. Those force you to escape quotes across two layers (JSON tool
    argument + shell/Python string) and the escaping WILL break (`unexpected EOF`,
    unmatched quote). The `write`/`edit` tools write bytes directly — no shell, no
    escaping needed.

16. If content contains both single and double quotes (e.g. HTML with `class="x"` and
    JS with `'y'`), that is fine for the `write` tool — write it verbatim. It is ONLY a
    problem inside shell/Python one-liners, which is exactly why you must not use them
    (see rule 15).
