-- Fix per-player match reports and expose safe round progress for the browser UI.
-- Each player reports their own win/loss. The round-level match_result is not used.

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
  v_total integer;
  v_submitted integer;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if p_match_result not in ('win', 'loss') then
    raise exception 'Invalid match result';
  end if;
  if p_task_completed is null then
    raise exception 'Please report whether you completed your task';
  end if;

  select r.room_id, r.status
  into v_room_id, v_status
  from public.rounds r
  where r.id = p_round_id
  for update;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if v_status <> 'playing' then
    raise exception 'This round is no longer accepting match reports';
  end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room_id
    and user_id = v_uid
    and left_at is null
    and id in (select player_id from public.assignments where round_id = p_round_id)
  returning id into v_player_id;
  if v_player_id is null then
    raise exception 'You are not an active player in this round';
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

-- This function reveals only counts and whether the caller has submitted.
-- It never returns another player's report or anyone's vote target.
create or replace function public.get_round_progress(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_status text;
  v_me uuid;
  v_reports_total integer;
  v_reports_received integer;
  v_votes_total integer;
  v_votes_received integer;
  v_my_report boolean;
  v_my_vote boolean;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status
  into v_room_id, v_status
  from public.rounds r
  where r.id = p_round_id;
  if v_room_id is null then raise exception 'Round not found'; end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room_id
    and user_id = v_uid
    and left_at is null
    and id in (select player_id from public.assignments where round_id = p_round_id)
  returning id into v_me;
  if v_me is null then raise exception 'You are not an active player in this round'; end if;

  select exists(
    select 1 from public.round_reports
    where round_id = p_round_id and player_id = v_me
  ) into v_my_report;

  select exists(
    select 1 from public.votes
    where round_id = p_round_id and voter_player_id = v_me
  ) into v_my_vote;

  select count(*) into v_reports_total
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  select count(*) into v_reports_received
  from public.round_reports rr
  join public.players p on p.id = rr.player_id
  where rr.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  select count(*) into v_votes_total
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  select count(*) into v_votes_received
  from public.votes v
  join public.players p on p.id = v.voter_player_id
  where v.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  return jsonb_build_object(
    'status', v_status,
    'reports_received', v_reports_received,
    'reports_total', v_reports_total,
    'votes_received', v_votes_received,
    'votes_total', v_votes_total,
    'my_report_submitted', v_my_report,
    'my_vote_submitted', v_my_vote
  );
end;
$$;

revoke all on function public.submit_round_report(uuid,text,boolean) from public, anon;
revoke all on function public.get_round_progress(uuid) from public, anon;
grant execute on function public.submit_round_report(uuid,text,boolean) to authenticated;
grant execute on function public.get_round_progress(uuid) to authenticated;
