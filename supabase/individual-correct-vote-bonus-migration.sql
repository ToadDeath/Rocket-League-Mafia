-- Award the teammate voting bonus only to teammates who personally voted for an imposter
-- who received the unique highest number of votes. A tie earns no voting bonus.
-- Run this migration in the Supabase SQL Editor.

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
  v_caller_id uuid;
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
  update public.players
  set last_seen_at = now()
  where room_id = v_room_id and user_id = v_uid and left_at is null
    and id in (select player_id from public.assignments where round_id = p_round_id)
  returning id into v_caller_id;
  if v_caller_id is null then
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
  join public.players target on target.id = v.target_player_id
  where v.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds'
    and target.left_at is null
    and target.last_seen_at > now() - interval '90 seconds';

  if v_votes <> v_players then raise exception 'Waiting for all active players to vote'; end if;
  if v_players < 2 then raise exception 'Not enough active players remain to finalize this round'; end if;

  select max(n) into v_max
  from (
    select count(*) n
    from public.votes v
    join public.players p on p.id = v.voter_player_id
    join public.players target on target.id = v.target_player_id
    where v.round_id = p_round_id
      and p.left_at is null
      and p.last_seen_at > now() - interval '90 seconds'
      and target.left_at is null
      and target.last_seen_at > now() - interval '90 seconds'
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
  join public.players target on target.id = v.target_player_id
  where v.round_id = p_round_id
    and p.left_at is null
    and p.last_seen_at > now() - interval '90 seconds'
    and target.left_at is null
    and target.last_seen_at > now() - interval '90 seconds'
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
    -- Only teammates who personally voted for the imposter receive the voting bonus.
    update public.players p
    set score = p.score + v_correct_pts
    from public.assignments a
    join public.votes v
      on v.round_id = a.round_id
     and v.voter_player_id = a.player_id
     and v.target_player_id = v_majority
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
    'teammate_vote_bonus', case
      when v_correct
       and v_my_role = 'teammate'
       and exists (
         select 1 from public.votes v
         where v.round_id = p_round_id
           and v.voter_player_id = v_my_player_id
           and v.target_player_id = v_majority
       ) then coalesce((v_settings->>'correct_vote_points')::integer, 2)
      else 0 end,
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
