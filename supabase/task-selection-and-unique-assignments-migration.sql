-- Host-managed task selection and unique task assignment.
-- Run this in the Supabase SQL Editor after the existing game migrations.

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
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code));
  if not found then raise exception 'Room not found'; end if;
  if v_room.created_by <> auth.uid() then raise exception 'Only the host can manage tasks'; end if;
  if v_room.status <> 'waiting' then raise exception 'Task selection is locked after the game starts'; end if;

  if v_room.settings ? 'selected_task_ids' then
    select coalesce(array_agg(value::uuid), '{}'::uuid[])
    into v_selected_ids
    from jsonb_array_elements_text(v_room.settings->'selected_task_ids');
  else
    select coalesce(array_agg(id), '{}'::uuid[])
    into v_selected_ids
    from public.tasks where active;
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

create or replace function public.save_task_selection(p_room_code text, p_task_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_room public.rooms%rowtype;
  v_ids uuid[];
  v_valid_count integer;
  v_team_count integer;
  v_imp_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code))
  for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.created_by <> auth.uid() then raise exception 'Only the host can manage tasks'; end if;
  if v_room.status <> 'waiting' then raise exception 'Task selection is locked after the game starts'; end if;

  select coalesce(array_agg(distinct id), '{}'::uuid[])
  into v_ids
  from unnest(coalesce(p_task_ids, '{}'::uuid[])) as requested(id);

  select count(*) into v_valid_count
  from public.tasks
  where active and id = any(v_ids);
  if v_valid_count <> cardinality(v_ids) then
    raise exception 'One or more selected tasks are no longer available';
  end if;

  select count(*) into v_team_count
  from public.tasks where active and role = 'teammate' and id = any(v_ids);
  select count(*) into v_imp_count
  from public.tasks where active and role = 'imposter' and id = any(v_ids);
  if v_team_count = 0 or v_imp_count = 0 then
    raise exception 'Select at least one task for both roles';
  end if;

  update public.rooms
  set settings = settings || jsonb_build_object('selected_task_ids', to_jsonb(v_ids))
  where id = v_room.id;

  return jsonb_build_object(
    'saved', true,
    'teammate_tasks', v_team_count,
    'imposter_tasks', v_imp_count
  );
end;
$$;

create or replace function public.start_round(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_round public.rounds%rowtype;
  v_count integer;
  v_imposters integer;
  v_teammates integer;
  v_task_ids uuid[];
  v_team_tasks integer;
  v_imp_tasks integer;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code))
  for update;
  if not found then raise exception 'Room not found'; end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room.id
    and user_id = v_uid
    and left_at is null;
  if not found then raise exception 'You are not an active member of this room'; end if;

  if exists (
    select 1 from public.rounds
    where room_id = v_room.id and status <> 'completed'
  ) then
    raise exception 'The previous round is not finished';
  end if;

  select count(*) into v_count
  from public.players
  where room_id = v_room.id
    and left_at is null
    and last_seen_at > now() - interval '90 seconds';

  v_imposters := greatest(1, coalesce((v_room.settings->>'imposter_count')::integer, 1));
  v_teammates := v_count - v_imposters;
  if v_count < 3 then raise exception 'At least 3 active players are needed to start'; end if;
  if v_imposters >= v_count then raise exception 'There must be at least one teammate'; end if;

  if v_room.settings ? 'selected_task_ids' then
    select coalesce(array_agg(value::uuid), '{}'::uuid[])
    into v_task_ids
    from jsonb_array_elements_text(v_room.settings->'selected_task_ids');
  else
    select coalesce(array_agg(id), '{}'::uuid[])
    into v_task_ids
    from public.tasks where active;
  end if;

  select count(*) into v_team_tasks
  from public.tasks where active and role = 'teammate' and id = any(v_task_ids);
  select count(*) into v_imp_tasks
  from public.tasks where active and role = 'imposter' and id = any(v_task_ids);

  if v_team_tasks < v_teammates then
    raise exception 'You need at least % selected teammate tasks for this round. Currently selected: %.',
      v_teammates, v_team_tasks;
  end if;
  if v_imp_tasks < v_imposters then
    raise exception 'You need at least % selected imposter tasks for this round. Currently selected: %.',
      v_imposters, v_imp_tasks;
  end if;

  insert into public.rounds(room_id, round_number, status)
  select v_room.id, coalesce(max(round_number), 0) + 1, 'playing'
  from public.rounds
  where room_id = v_room.id
  returning * into v_round;

  with ranked as (
    select p.id as player_id,
           row_number() over(order by random()) as rn
    from public.players p
    where p.room_id = v_room.id
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
  ),
  chosen as (
    select player_id,
           case when rn <= v_imposters then 'imposter' else 'teammate' end as role,
           case when rn <= v_imposters then rn else rn - v_imposters end as role_rn
    from ranked
  ),
  available_tasks as (
    select t.id, t.role,
           row_number() over(partition by t.role order by random()) as role_rn
    from public.tasks t
    where t.active and t.id = any(v_task_ids)
  )
  insert into public.assignments(round_id, player_id, role, task_id)
  select v_round.id, c.player_id, c.role, t.id
  from chosen c
  join available_tasks t
    on t.role = c.role and t.role_rn = c.role_rn;

  update public.rounds set imposter_player_id = (
    select player_id from public.assignments
    where round_id = v_round.id and role = 'imposter'
    order by random() limit 1
  ) where id = v_round.id;

  update public.rooms set status = 'playing' where id = v_room.id;
  return jsonb_build_object(
    'round_id', v_round.id,
    'round_number', v_round.round_number,
    'players_in_round', v_count
  );
end;
$$;

revoke all on function public.get_lobby_tasks(text) from public, anon;
revoke all on function public.save_task_selection(text, uuid[]) from public, anon;
grant execute on function public.get_lobby_tasks(text) to authenticated;
grant execute on function public.save_task_selection(text, uuid[]) to authenticated;
