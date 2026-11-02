-- Return the completed round's voting outcome and leaderboard details.
-- This is read-only and does not change scores.

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
  v_max_votes integer := 0;
  v_leader_count integer := 0;
  v_majority uuid;
  v_tie boolean := false;
  v_correct boolean := false;
  v_imposters jsonb := '[]'::jsonb;
  v_leaderboard jsonb := '[]'::jsonb;
  v_identified_name text;
  v_imp_bonus integer := 0;
  v_teammate_bonus integer := 0;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;

  select r.room_id, r.status, rm.settings
    into v_room_id, v_status, v_settings
  from public.rounds r
  join public.rooms rm on rm.id = r.room_id
  where r.id = p_round_id;

  if v_room_id is null then raise exception 'Round not found'; end if;
  if not exists (
    select 1 from public.players
    where room_id = v_room_id and user_id = v_uid
  ) then raise exception 'You are not in this room'; end if;
  if v_status <> 'completed' then raise exception 'Results are not available yet'; end if;

  select coalesce(max(vote_count), 0)
    into v_max_votes
  from (
    select count(*) as vote_count
    from public.votes
    where round_id = p_round_id
    group by target_player_id
  ) counts;

  select count(*)
    into v_leader_count
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
    from public.players p
    where p.id = v_majority;

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
    jsonb_build_object('player_id', p.id, 'display_name', p.display_name, 'score', p.score)
    order by p.score desc, p.display_name
  ), '[]'::jsonb)
  into v_leaderboard
  from public.players p
  where p.room_id = v_room_id;

  v_teammate_bonus := coalesce((v_settings->>'correct_vote_points')::integer, 2);

  if not v_tie and not v_correct and v_majority is not null then
    if exists (
      select 1
      from public.assignments a
      join public.votes v on v.round_id = a.round_id and v.voter_player_id = a.player_id
      where a.round_id = p_round_id
        and a.role = 'imposter'
        and v.target_player_id = v_majority
    ) then
      v_imp_bonus := coalesce((v_settings->>'imposter_majority_alignment_bonus')::integer, 2);
    end if;
  end if;

  return jsonb_build_object(
    'tie', v_tie,
    'correct_vote', v_correct,
    'identified_player_id', v_majority,
    'identified_player', v_identified_name,
    'imposters', v_imposters,
    'teammate_vote_bonus', case when v_correct then v_teammate_bonus else 0 end,
    'imposter_alignment_bonus', v_imp_bonus,
    'leaderboard', v_leaderboard
  );
end;
$$;

revoke all on function public.get_round_results(uuid) from public, anon;
grant execute on function public.get_round_results(uuid) to authenticated;
