-- Clarify task wording so numeric goals are minimums, not exact totals.
-- Run this in the Supabase SQL Editor.

begin;

update public.tasks
set task_text = 'Get at least 2 assists'
where role = 'teammate' and task_text = 'Get 2 assists';

update public.tasks
set task_text = 'Get at least 5 shots on goal'
where role = 'teammate' and task_text = 'Get 5 shots on goal';

update public.tasks
set task_text = 'Force the game into overtime'
where role = 'teammate' and task_text = 'Force the game into Overtime';

commit;
