-- Allow any signed-in player with the room code to view the lobby task list.
-- Task visibility is not secret; only the host can change task selection.
-- Run this as a new query in the Supabase SQL Editor.

create or replace function public.get_lobby_tasks(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_room public.rooms%rowtype;
  v_selected_ids uuid[];
  v_tasks jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;

  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code));

  if not found then
    raise exception 'Room not found';
  end if;

  if v_room.status <> 'waiting' then
    raise exception 'The task list is only available in the lobby';
  end if;

  if v_room.settings ? 'selected_task_ids' then
    select coalesce(array_agg(value::uuid), '{}'::uuid[])
    into v_selected_ids
    from jsonb_array_elements_text(v_room.settings->'selected_task_ids');
  else
    select coalesce(array_agg(id), '{}'::uuid[])
    into v_selected_ids
    from public.tasks
    where active;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', t.id,
      'role', t.role,
      'task_text', t.task_text,
      'selected', t.id = any(v_selected_ids)
    ) order by t.role, t.task_text
  ), '[]'::jsonb)
  into v_tasks
  from public.tasks t
  where t.active;

  return jsonb_build_object('tasks', v_tasks);
end;
$$;

revoke all on function public.get_lobby_tasks(text) from public, anon;
grant execute on function public.get_lobby_tasks(text) to authenticated;
