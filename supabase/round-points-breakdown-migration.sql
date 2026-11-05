-- Add an exact per-player breakdown of the points awarded for a completed round.
-- Run this migration in the Supabase SQL Editor after the frontend update is committed.

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
  v_match_result text;
  v_task_completed boolean := false;
  v_match_points integer := 0;
  v_task_points integer := 0;
  v_vote_points integer := 0;
  v_correct_pts integer;
  v_imp_bonus integer;
  v_imp_loss integer;
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

  select rr.match_result, rr.task_completed
    into v_match_result, v_task_completed
  from public.round_reports rr
  where rr.round_id = p_round_id and rr.player_id = v_my_player_id;

  v_correct_pts := coalesce((v_settings->>'correct_vote_points')::integer, 2);
  v_imp_bonus := coalesce((v_settings->>'imposter_majority_alignment_bonus')::integer, 2);
  v_imp_loss := coalesce((v_settings->>'imposter_loss_points')::integer, 5);

  if v_my_role = 'teammate' then
    v_match_points := case when v_match_result = 'win'
      then coalesce((v_settings->>'teammate_win_points')::integer, 2) else 0 end;
    v_task_points := case when coalesce(v_task_completed, false)
      then coalesce((v_settings->>'teammate_task_points')::integer, 3) else 0 end;
  else
    v_match_points := case when v_match_result = 'loss'
      then v_imp_loss else 0 end;
    v_task_points := case when coalesce(v_task_completed, false)
      then coalesce((v_settings->>'imposter_task_points')::integer, 3) else 0 end;
  end if;

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

  if v_my_role = 'teammate' and v_correct and exists (
    select 1 from public.votes v
    where v.round_id = p_round_id
      and v.voter_player_id = v_my_player_id
      and v.target_player_id = v_majority
  ) then
    v_vote_points := v_correct_pts;
  elsif v_my_role = 'imposter' and v_correct then
    v_vote_points := -v_imp_loss;
  elsif v_my_role = 'imposter' and not v_tie and exists (
    select 1 from public.votes v
    where v.round_id = p_round_id
      and v.voter_player_id = v_my_player_id
      and v.target_player_id = v_majority
  ) then
    v_vote_points := v_imp_bonus;
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
    'my_match_result', v_match_result,
    'my_task_completed', coalesce(v_task_completed, false),
    'match_points', v_match_points,
    'task_points', v_task_points,
    'vote_points', v_vote_points,
    'teammate_vote_bonus', case when v_vote_points > 0 and v_my_role = 'teammate'
      then v_vote_points else 0 end,
    'imposter_alignment_bonus', case when v_vote_points > 0 and v_my_role = 'imposter'
      then v_vote_points else 0 end,
    'leaderboard', v_leaderboard
  );
end;
$$;
