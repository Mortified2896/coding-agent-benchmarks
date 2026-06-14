# Learn Chinese Like a Baby: HSK 1 Baserow DB

Design and, if a throwaway Baserow test target is available, implement a practical Baserow database for the HSK 1 vocabulary video series.

Requirements:
- Focus on HSK 1 vocabulary tracking.
- Skip line-by-line dialogue tracking for now.
- Tables should likely include Episodes, HSK Vocabulary, Episode Vocabulary Usage, and Assets.
- Track whether words are introduced, reviewed, underused, missing, and how often they appear.
- Make the Baserow design practical, visually usable, and API-ready later.
- Build/design only against this run's isolated Baserow test target. Do not touch a production DB.

Write these outputs to /benchmark/output:
- schema_spec.md
- implementation_notes.md
- baserow_result.md
- api_payloads/ with any API payloads used

Baserow targets for comparison:
- Production database/workspace, not for benchmark writes: Learn Chinese Like A Baby
- Low reasoning benchmark: hsk1_design_gpt55_low
- Medium reasoning benchmark: hsk1_design_gpt55_medium
