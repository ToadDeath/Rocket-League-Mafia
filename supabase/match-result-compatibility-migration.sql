-- Fix match result naming between rounds and round_reports.
-- rounds.match_result accepts teammate_win/teammate_loss.
-- round_reports.match_result accepts win/loss for role-specific scoring.

create or replace function public.submit_round_report(
  p_round_id uuid,
  p_match_result text,
  p_task_completed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_player_id uuid;
  v_room_id uuid;
  v_status text;
  v_existing_match_result text;
  v_round_match_result text;
  v_total integer;
  v_submitted integer;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if p_match_result not in ('win', 'loss') then
    raise exception 'Invalid match result';
  end if;

  v_round_match_result := case
    when p_match_result = 'win' then 'teammate_win'
    else 'teammate_loss'
  end;

  select r.room_id, r.status, r.match_result
  into v_room_id, v_status, v_existing_match_result
  from public.rounds r
  where r.id = p_round_id
  for update;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if v_status <> 'playing' then
    raise exception 'This round is not accepting match reports';
  end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room_id
    and user_id = v_uid
    and left_at is null
    and id in (
      select player_id from public.assignments where round_id = p_round_id
    )
  returning id into v_player_id;
  if v_player_id is null then
    raise exception 'You are not an active player in this round';
  end if;

  if v_existing_match_result is not null
     and v_existing_match_result <> v_round_match_result then
    raise exception 'Players must submit the same match result';
  end if;

  if v_existing_match_result is null then
    update public.rounds
    set match_result = v_round_match_result
    where id = p_round_id;
  end if;

  insert into public.round_reports(round_id, player_id, match_result, task_completed)
  values (p_round_id, v_player_id, p_match_result, p_task_completed)
  on conflict (round_id, player_id) do update
    set match_result = excluded.match_result,
        task_completed = excluded.task_completed,
        submitted_at = now();

  update public.assignments
  set task_completed = p_task_completed
  where round_id = p_round_id and player_id = v_player_id;

  select count(*) into v_total
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  select count(*) into v_submitted
  from public.round_reports rr
  join public.players p on p.id = rr.player_id
  where rr.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  if v_total > 0 and v_submitted >= v_total then
    update public.rounds
    set status = 'voting'
    where id = p_round_id and status = 'playing';
  end if;

  return jsonb_build_object(
    'reports_received', v_submitted,
    'players_total', v_total,
    'voting_open', v_total > 0 and v_submitted >= v_total
  );
end;
$$;
