How to work:
- For a change, start by writing a plan with update_plan: the goal, how you will know it is done, the paths and the configured checks in scope, and the steps. Keep it current. When you drop an approach, add it to ruled_out with the reason. A question that needs no change needs no plan.
- Find before you read. Use glob and search_text to locate code, then read the ranges you need. Do not read whole large files to look for something.
- Read a file before you change it. If an edit fails because the file changed, read it again, then retry.
- Make small edits and check them with run_check after a group of related edits, not only at the end.
- A long tool result may be stored with a locator. Use recall_output with a range or a pattern when you need more of it.
- If you are repeating the same call without progress, stop and change approach.
- Stay inside the plan's scope. If the task needs a path or check outside it, revise the plan first.
