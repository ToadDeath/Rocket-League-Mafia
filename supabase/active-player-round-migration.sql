-- Rocket League Mafia: use the live player roster for round flow and voting.
-- Run after presence-migration.sql and inactivity-cleanup-migration.sql.
-- A player is currently active when they have not left and checked in within 90 seconds.

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
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code))
  for update;
  if not found then raise exception 'Room not found'; end if;

  -- The caller is active because this request itself is a check-in.
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
  if v_count < 3 then raise exception 'At least 3 active players are needed to start'; end if;
  if v_imposters >= v_count then raise exception 'There must be at least one teammate'; end if;
  if not exists (select 1 from public.tasks where active and role = 'teammate')
     or not exists (select 1 from public.tasks where active and role = 'imposter') then
    raise exception 'Task library is missing tasks for one or more roles';
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
           case when rn <= v_imposters then 'imposter' else 'teammate' end as role
    from ranked
  )
  insert into public.assignments(round_id, player_id, role, task_id)
  select v_round.id, c.player_id, c.role, t.id
  from chosen c
  cross join lateral (
    select id
    from public.tasks
    where active and role = c.role
    order by random()
    limit 1
  ) t;

  update public.rounds
  set imposter_player_id = (
    select player_id
    from public.assignments
    where round_id = v_round.id and role = 'imposter'
    order by random()
    limit 1
  )
  where id = v_round.id;

  update public.rooms set status = 'playing' where id = v_room.id;
  return jsonb_build_object('round_id', v_round.id, 'round_number', v_round.round_number,
                            'players_in_round', v_count);
end;
$$;


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
  v_total integer;
  v_submitted integer;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if p_match_result not in ('win', 'loss') then raise exception 'Invalid match result'; end if;

  -- Lock the round so simultaneous reports cannot race the status transition.
  select r.room_id, r.status, r.match_result
  into v_room_id, v_status, v_existing_match_result
  from public.rounds r
  where r.id = p_round_id
  for update;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if v_status <> 'playing' then raise exception 'This round is not accepting match reports'; end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room_id
    and user_id = v_uid
    and left_at is null
    and id in (
      select player_id from public.assignments where round_id = p_round_id
    )
  returning id into v_player_id;
  if v_player_id is null then raise exception 'You are not an active player in this round'; end if;

  if v_existing_match_result is not null and v_existing_match_result <> p_match_result then
    raise exception 'Players must submit the same match result';
  end if;
  if v_existing_match_result is null then
    update public.rounds set match_result = p_match_result where id = p_round_id;
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
    update public.rounds set status = 'voting' where id = p_round_id and status = 'playing';
  end if;

  return jsonb_build_object('reports_received', v_submitted,
                            'players_total', v_total,
                            'voting_open', v_total > 0 and v_submitted >= v_total);
end;
$$;


create or replace function public.submit_vote(p_round_id uuid, p_target_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_voter uuid;
  v_room uuid;
  v_status text;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status
  into v_room, v_status
  from public.rounds r
  where r.id = p_round_id;
  if v_room is null then raise exception 'Round not found'; end if;
  if v_status <> 'voting' then raise exception 'Voting is not open yet'; end if;

  update public.players
  set last_seen_at = now()
  where room_id = v_room
    and user_id = v_uid
    and left_at is null
    and id in (
      select player_id from public.assignments where round_id = p_round_id
    )
  returning id into v_voter;
  if v_voter is null then raise exception 'You are not an active player in this round'; end if;

  if not exists (
    select 1
    from public.assignments a
    join public.players p on p.id = a.player_id
    where a.round_id = p_round_id
      and a.player_id = p_target_player_id
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
  ) then
    raise exception 'Vote target is not an active player in this round';
  end if;
  if p_target_player_id = v_voter then raise exception 'You cannot vote for yourself'; end if;

  insert into public.votes(round_id, voter_player_id, target_player_id)
  values (p_round_id, v_voter, p_target_player_id)
  on conflict (round_id, voter_player_id) do update
    set target_player_id = excluded.target_player_id,
        created_at = now();

  return jsonb_build_object('vote_submitted', true);
end;
$$;


create or replace function public.finalize_round(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_status text;
  v_players integer;
  v_votes integer;
  v_max integer;
  v_leaders integer;
  v_majority uuid;
  v_imposters uuid[];
  v_correct boolean := false;
  v_tie boolean := false;
  v_settings jsonb;
  v_correct_pts integer;
  v_imp_bonus integer;
  v_imp_loss integer;
  v_changes jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status, rm.settings
  into v_room_id, v_status, v_settings
  from public.rounds r
  join public.rooms rm on rm.id = r.room_id
  where r.id = p_round_id
  for update of r;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if v_status = 'completed' then raise exception 'This round has already been finalized'; end if;
  if v_status <> 'voting' then raise exception 'This round is not ready to finalize'; end if;

  -- The caller is active because this request itself is a check-in.
  if not exists (
    update public.players
    set last_seen_at = now()
    where room_id = v_room_id and user_id = v_uid and left_at is null
      and id in (select player_id from public.assignments where round_id = p_round_id)
    returning id
  ) then
    raise exception 'You are not an active player in this round';
  end if;

  select count(*) into v_players
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  select count(*) into v_votes
  from public.votes v
  join public.players p on p.id = v.voter_player_id
  where v.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  if v_votes <> v_players then raise exception 'Waiting for all active players to vote'; end if;
  if v_players < 2 then raise exception 'Not enough active players remain to finalize this round'; end if;

  select max(n) into v_max
  from (
    select count(*) n
    from public.votes v
    join public.players p on p.id = v.voter_player_id
    where v.round_id = p_round_id
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
    group by v.target_player_id
  ) q;

  select count(*) into v_leaders
  from (
    select v.target_player_id, count(*) n
    from public.votes v
    join public.players p on p.id = v.voter_player_id
    where v.round_id = p_round_id
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
    group by v.target_player_id
    having count(*) = v_max
  ) q;

  select v.target_player_id into v_majority
  from public.votes v
  join public.players p on p.id = v.voter_player_id
  where v.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds'
  group by v.target_player_id
  having count(*) = v_max
  limit 1;

  v_tie := v_leaders <> 1;
  select array_agg(a.player_id) into v_imposters
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id
    and a.role = 'imposter'
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  v_correct := not v_tie and exists (
    select 1
    from public.assignments a
    join public.players p on p.id = a.player_id
    where a.round_id = p_round_id
      and a.player_id = v_majority
      and a.role = 'imposter'
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
  );

  -- Score only players who are active members of this round at finalization.
  update public.players p
  set score = p.score +
    case when a.role = 'teammate' then
      (case when rr.task_completed then coalesce((v_settings->>'teammate_task_points')::integer, 3) else 0 end) +
      (case when rr.match_result = 'win' then coalesce((v_settings->>'teammate_win_points')::integer, 2) else 0 end)
    else
      (case when rr.task_completed then coalesce((v_settings->>'imposter_task_points')::integer, 3) else 0 end) +
      (case when rr.match_result = 'loss' then coalesce((v_settings->>'imposter_loss_points')::integer, 5) else 0 end)
    end
  from public.assignments a
  join public.round_reports rr on rr.round_id = a.round_id and rr.player_id = a.player_id
  where a.round_id = p_round_id
    and p.id = a.player_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds';

  v_correct_pts := coalesce((v_settings->>'correct_vote_points')::integer, 2);
  v_imp_bonus := coalesce((v_settings->>'imposter_majority_alignment_bonus')::integer, 2);
  v_imp_loss := coalesce((v_settings->>'imposter_loss_points')::integer, 5);

  if v_correct then
    update public.players p
    set score = p.score + v_correct_pts
    from public.assignments a
    where a.round_id = p_round_id
      and a.player_id = p.id
      and a.role = 'teammate'
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds';

    update public.players p
    set score = p.score - v_imp_loss
    where p.id = any(v_imposters);
  elsif not v_tie then
    update public.players p
    set score = p.score + v_imp_bonus
    where p.id in (
      select a.player_id
      from public.assignments a
      join public.votes v on v.round_id = a.round_id and v.voter_player_id = a.player_id
      join public.players voter on voter.id = a.player_id
      where a.round_id = p_round_id
        and a.role = 'imposter'
        and v.target_player_id = v_majority
        and voter.left_at is null
        and voter.last_seen_at > now() - interval '90 seconds'
    );
  end if;

  update public.rounds set status = 'completed' where id = p_round_id;
  if not exists (
    select 1 from public.rounds
    where room_id = v_room_id and status <> 'completed'
  ) then
    update public.rooms set status = 'waiting' where id = v_room_id;
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('player_id', p.id, 'display_name', p.display_name, 'score', p.score)
              order by p.score desc),
    '[]'::jsonb
  )
  into v_changes
  from public.players p
  where p.room_id = v_room_id;

  return jsonb_build_object(
    'tie', v_tie,
    'correct_vote', v_correct,
    'identified_player_id', case when v_tie then null else v_majority end,
    'imposter_player_ids', to_jsonb(v_imposters),
    'leaderboard', v_changes,
    'active_players_counted', v_players
  );
end;
$$;
