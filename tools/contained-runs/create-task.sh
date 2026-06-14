#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'Usage: %s --task <task-folder> [--force]\n' "$0" >&2; exit 64; }
task=""; force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$task" ]] || usage

mkdir -p "$task/input" "$task/runs" "$task/evaluation"
write_file() {
  local path="$1" content="$2"
  if [[ -e "$path" && "$force" -ne 1 ]]; then
    printf 'Refusing to overwrite existing file: %s (use --force)\n' "$path" >&2
    exit 1
  fi
  printf '%s\n' "$content" > "$path"
}

write_file "$task/input/task.md" '# Learn Chinese Like a Baby: HSK 1 Baserow DB

Design and, when a throwaway Baserow test target is available, implement a practical Baserow database for an HSK 1 vocabulary video series.

Scope:
- Focus on HSK 1 vocabulary tracking.
- Skip line-by-line dialogue tracking for now.
- Include tables for Episodes, HSK Vocabulary, Episode Vocabulary Usage, and Assets unless you justify a better structure.
- Track introduced, reviewed, underused, missing, and frequency information.
- Make the design visually usable in Baserow and API-ready for later automation.
- Use only the throwaway test Baserow target provided for this run. Do not touch production databases.

Required outputs in /benchmark/output:
- schema_spec.md
- implementation_notes.md
- baserow_result.md
- api_payloads/ with any payloads used, if API implementation is attempted
'
write_file "$task/input/context.md" '# Context

The Learn Chinese Like a Baby HSK 1 series needs a small operational database for planning and auditing vocabulary coverage across episodes. The database should help creators see which HSK 1 words have been introduced, which are reviewed, which are underused, and which are still missing.

Prioritize a design that a non-engineer can inspect in Baserow while preserving stable field names and relationships for future API automation. Avoid overbuilding dialogue-level transcript tracking in this benchmark.
'
write_file "$task/input/rubric.md" '# Rubric

Score each run from 1-5 on:
1. HSK 1 vocabulary coverage model: completeness of tables and fields for introduced/reviewed/underused/missing words.
2. Practical Baserow usability: clear table names, useful views, field types, and relationships.
3. API readiness: stable names, IDs or slugs, payload clarity, and automation notes.
4. Isolation discipline: uses only the run-specific throwaway target and writes only to /benchmark/output.
5. Implementation evidence: schema_spec.md, implementation_notes.md, baserow_result.md, and API payloads are concrete and reproducible.
'
mkdir -p "$task/runs/gpt55-small" "$task/runs/gpt55-medium"
printf 'Created task scaffold at %s\n' "$task"
