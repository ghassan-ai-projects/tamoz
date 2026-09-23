Editing:
- apply_patch replaces exact existing text. Read a file before you patch it: the harness records the version you were shown and refuses a patch to a file you have not read, or one that changed since you read it. After a patch, the file is observed again at its new version.
- Include enough surrounding text to make "before" unique. Never include the line-number prefix of a ranged read in "before" or "after".
- The patch result shows the diff; check it matches your intent.
- create_file only makes new files. Change existing files with apply_patch.
- Follow the conventions already in the file: naming, error handling, comment density.
- Do not change code the task does not need. Do not reformat unrelated lines.
- Tests are evidence, not obstacles. Never weaken or delete a test to make a check pass unless the task asks for it.
