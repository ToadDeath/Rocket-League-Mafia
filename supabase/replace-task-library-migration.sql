-- Replace the old task library with the current Rocket League Mafia tasks.
-- Run this in the Supabase SQL Editor after task-selection-and-unique-assignments-migration.sql.
-- Safe to run more than once.

begin;

-- Retire every task currently in the library so old tasks cannot be selected.
update public.tasks
set active = false
where active = true;

-- Add the new tasks if they do not already exist.
insert into public.tasks (role, task_text, active)
select new_tasks.role, new_tasks.task_text, true
from (values
  ('teammate', 'Get MVP'),
  ('teammate', 'Get 2 assists'),
  ('teammate', 'Score at least 1 goal'),
  ('teammate', 'Get at least 3 saves'),
  ('teammate', 'Get 5 shots on goal'),
  ('teammate', 'Score the first goal'),
  ('teammate', 'Score a pinch goal'),
  ('teammate', 'Score an aerial goal'),
  ('teammate', 'Score a flick goal'),
  ('teammate', 'Force the game into Overtime'),
  ('imposter', 'Do not score a goal'),
  ('imposter', 'Score an own goal'),
  ('imposter', 'Finish with no more than 3 shots'),
  ('imposter', 'Get demoed at least 2 times'),
  ('imposter', 'Finish with no more than 1 save'),
  ('imposter', 'Allow the opposing team to score first'),
  ('imposter', 'Get at least 3 demos')
) as new_tasks(role, task_text)
where not exists (
  select 1
  from public.tasks existing
  where existing.role = new_tasks.role
    and existing.task_text = new_tasks.task_text
);

-- Ensure these exact tasks are active, including if this migration is rerun.
update public.tasks
set active = true
where (role, task_text) in (
  ('teammate', 'Get MVP'),
  ('teammate', 'Get 2 assists'),
  ('teammate', 'Score at least 1 goal'),
  ('teammate', 'Get at least 3 saves'),
  ('teammate', 'Get 5 shots on goal'),
  ('teammate', 'Score the first goal'),
  ('teammate', 'Score a pinch goal'),
  ('teammate', 'Score an aerial goal'),
  ('teammate', 'Score a flick goal'),
  ('teammate', 'Force the game into Overtime'),
  ('imposter', 'Do not score a goal'),
  ('imposter', 'Score an own goal'),
  ('imposter', 'Finish with no more than 3 shots'),
  ('imposter', 'Get demoed at least 2 times'),
  ('imposter', 'Finish with no more than 1 save'),
  ('imposter', 'Allow the opposing team to score first'),
  ('imposter', 'Get at least 3 demos')
);

-- Clear saved task selections so existing waiting rooms start with the new
-- complete task library selected instead of retaining IDs from retired tasks.
update public.rooms
set settings = settings - 'selected_task_ids'
where settings ? 'selected_task_ids';

commit;
