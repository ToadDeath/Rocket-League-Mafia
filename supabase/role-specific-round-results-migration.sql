-- Role-specific round results with exact score changes and leaderboard movement.
-- Run this in the Supabase SQL Editor after the existing round-results-feedback migration.
-- Score snapshots are captured automatically when a round's assignments are created.

create table if not exists public.round_score_snapshots (
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  score_before integer not null,
  primary key (round_id, player_id)
);

alter table public.round_score_snapshots enable row level security;
revoke all on public.round_score_snapshots from public, anon, authenticated;

create or replace function public.capture_round_score_snapshot()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.round_score_snapshots(round_id, player_id, score_before)
  select new.round_id, p.id, p.score
  from public.players p
  where p.id = new.player_id
  on conflict (round_id, player_id) do nothing;
  return new;
end;
$$;

drop trigger if exists assignments_capture_score_snapshot on public.assignments;
create trigger assignments_capture_score_snapshot
after insert on public.assignments
for each row execute function public.capture_round_score_snapshot();

create or replace function public.get_round_results(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_status text;
  v_settings jsonb;
  v_my_player_id uuid;
  v_my_role text;
  v_max_votes integer := 0;
  v_leader_count integer := 0;
  v_majority uuid;
  v_tie boolean := false;
  v_correct boolean := false;
  v_imposters jsonb := '[]'::jsonb;
  v_leaderboard jsonb := '[]'::jsonb;
  v_identified_name text;
  v_my_delta integer := 0;
  v_round_number integer;
  v_cards jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status, rm.settings, r.round_number
    into v_room_id, v_status, v_settings, v_round_number
  from public.rounds r
  join public.rooms rm on rm.id = r.room_id
  where r.id = p_round_id;

  if v_room_id is null then raise exception 'Round not found'; end if;
  if v_status <> 'completed' then raise exception 'Results are not available yet'; end if;

  select p.id into v_my_player_id
  from public.players p
  where p.room_id = v_room_id and p.user_id = v_uid
  limit 1;
  if v_my_player_id is null then raise exception 'You are not in this room'; end if;

  select a.role into v_my_role
  from public.assignments a
  where a.round_id = p_round_id and a.player_id = v_my_player_id;

  select coalesce(max(vote_count), 0) into v_max_votes
  from (
    select count(*) as vote_count
    from public.votes
    where round_id = p_round_id
    group by target_player_id
  ) counts;

  select count(*) into v_leader_count
  from (
    select target_player_id
    from public.votes
    where round_id = p_round_id
    group by target_player_id
    having count(*) = v_max_votes
  ) leaders
  where v_max_votes > 0;

  v_tie := v_leader_count <> 1;

  if not v_tie then
    select target_player_id into v_majority
    from public.votes
    where round_id = p_round_id
    group by target_player_id
    having count(*) = v_max_votes
    limit 1;

    select p.display_name into v_identified_name
    from public.players p where p.id = v_majority;

    select exists (
      select 1 from public.assignments a
      where a.round_id = p_round_id
        and a.player_id = v_majority
        and a.role = 'imposter'
    ) into v_correct;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('player_id', p.id, 'display_name', p.display_name)
    order by p.display_name
  ), '[]'::jsonb)
  into v_imposters
  from public.assignments a
  join public.players p on p.id = a.player_id
  where a.round_id = p_round_id and a.role = 'imposter';

  select coalesce(jsonb_agg(
    jsonb_build_object('player_id', p.id, 'display_name', p.display_name,
      'role', a.role, 'task_text', t.task_text)
    order by p.display_name
  ), '[]'::jsonb)
  into v_cards
  from public.assignments a
  join public.players p on p.id = a.player_id
  join public.tasks t on t.id = a.task_id
  where a.round_id = p_round_id;

  with standings as (
    select
      p.id,
      p.display_name,
      p.score,
      coalesce(p.score - snap.score_before, 0) as delta,
      row_number() over (order by p.score desc, p.display_name asc) as rank_after,
      row_number() over (order by coalesce(snap.score_before, p.score) desc, p.display_name asc) as rank_before
    from public.players p
    left join public.round_score_snapshots snap
      on snap.player_id = p.id and snap.round_id = p_round_id
    where p.room_id = v_room_id
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'player_id', id,
        'display_name', display_name,
        'score', score,
        'round_points', delta,
        'rank_before', rank_before,
        'rank_after', rank_after,
        'rank_change', rank_before - rank_after,
        'is_you', id = v_my_player_id
      ) order by rank_after
    ), '[]'::jsonb),
    coalesce(max(delta) filter (where id = v_my_player_id), 0)
  into v_leaderboard, v_my_delta
  from standings;

  return jsonb_build_object(
    'tie', v_tie,
    'correct_vote', v_correct,
    'identified_player_id', v_majority,
    'identified_player', v_identified_name,
    'imposters', v_imposters,
    'my_role', v_my_role,
    'round_number', v_round_number,
    'cards', v_cards,
    'my_round_points', v_my_delta,
    'teammate_vote_bonus', case when v_correct then coalesce((v_settings->>'correct_vote_points')::integer, 2) else 0 end,
    'imposter_alignment_bonus', case
      when not v_tie and not v_correct and exists (
        select 1 from public.assignments a
        join public.votes v on v.round_id = a.round_id and v.voter_player_id = a.player_id
        where a.round_id = p_round_id
          and a.role = 'imposter'
          and v.target_player_id = v_majority
      ) then coalesce((v_settings->>'imposter_majority_alignment_bonus')::integer, 2)
      else 0 end,
    'leaderboard', v_leaderboard
  );
end;
$$;

revoke all on function public.get_round_results(uuid) from public, anon;
grant execute on function public.get_round_results(uuid) to authenticated;


-- Return the caller's own assignment, including their player name.
create or replace function public.get_my_assignment(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select jsonb_build_object(
    'role', a.role, 'task', t.task_text, 'player_name', p.display_name,
    'task_completed', a.task_completed, 'round_status', r.status,
    'round_number', r.round_number
  )
  into v_result
  from public.assignments a
  join public.players p on p.id = a.player_id
  join public.tasks t on t.id = a.task_id
  join public.rounds r on r.id = a.round_id
  where a.round_id = p_round_id and p.user_id = v_uid;
  if v_result is null then raise exception 'No assignment found for you in this round'; end if;
  return v_result;
end;
$$;

-- Include whether the caller created the room in lobby state.
create or replace function public.get_room_state(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_me uuid;
  v_round public.rounds%rowtype;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.rooms where code = upper(trim(p_room_code));
  if not found then raise exception 'Room not found'; end if;
  update public.players set last_seen_at = now()
  where room_id = v_room.id and user_id = v_uid and left_at is null
  returning id into v_me;
  if v_me is null then raise exception 'You are not an active member of this lobby'; end if;
  select * into v_round from public.rounds where room_id = v_room.id
    order by round_number desc limit 1;
  return jsonb_build_object(
    'room_code', v_room.code, 'room_status', v_room.status,
    'settings', v_room.settings, 'my_player_id', v_me,
    'is_creator', v_room.created_by = v_uid,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'score',p.score)
        order by p.joined_at)
      from public.players p
      where p.room_id = v_room.id and p.left_at is null
        and p.last_seen_at > now() - interval '90 seconds'
    ), '[]'::jsonb),
    'current_round', case when v_round.id is null then null else
      jsonb_build_object('id',v_round.id,'round_number',v_round.round_number,'status',v_round.status)
    end
  );
end;
$$;

-- The room creator alone can end the shared game, and only between rounds.
create or replace function public.end_game(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.rooms
  where code = upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.created_by <> v_uid then raise exception 'Only the lobby creator can end the game'; end if;
  if exists (select 1 from public.rounds where room_id = v_room.id and status <> 'completed') then
    raise exception 'Finish the current round before ending the game';
  end if;
  update public.rooms set status = 'finished' where id = v_room.id;
  return jsonb_build_object('ended', true);
end;
$$;

create or replace function public.get_game_results(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_status text;
  v_board jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select id, status into v_room_id, v_status from public.rooms
  where code = upper(trim(p_room_code));
  if v_room_id is null then raise exception 'Room not found'; end if;
  if not exists (select 1 from public.players where room_id = v_room_id and user_id = v_uid) then
    raise exception 'You are not in this room';
  end if;
  if v_status <> 'finished' then raise exception 'The game has not ended'; end if;
  select coalesce(jsonb_agg(
    jsonb_build_object('player_id', id, 'display_name', display_name, 'score', score)
    order by score desc, display_name
  ), '[]'::jsonb) into v_board
  from public.players where room_id = v_room_id;
  return jsonb_build_object('leaderboard', v_board);
end;
$$;

revoke all on function public.end_game(text) from public, anon;
revoke all on function public.get_game_results(text) from public, anon;
grant execute on function public.end_game(text) to authenticated;
grant execute on function public.get_game_results(text) to authenticated;
