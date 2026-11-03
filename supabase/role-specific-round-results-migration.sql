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
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status, rm.settings
    into v_room_id, v_status, v_settings
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
