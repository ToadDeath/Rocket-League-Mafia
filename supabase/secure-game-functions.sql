-- Rocket League Mafia: secure game RPCs
-- Run after the initial database foundation script.

create table if not exists public.round_reports (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  match_result text not null check (match_result in ('win','loss')),
  task_completed boolean not null,
  submitted_at timestamptz not null default now(),
  unique (round_id, player_id)
);

alter table public.round_reports enable row level security;

-- Keep all game tables inaccessible through direct client table queries.
revoke all on public.rooms, public.players, public.rounds, public.tasks,
  public.assignments, public.votes, public.round_reports from anon, authenticated;

create or replace function public.create_room(p_display_name text, p_settings jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player public.players%rowtype;
  v_code text;
  v_settings jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if length(trim(coalesce(p_display_name,''))) < 1 or length(trim(p_display_name)) > 18 then
    raise exception 'Player name must be 1 to 18 characters';
  end if;

  v_settings := jsonb_build_object(
    'imposter_count', 1,
    'teammate_task_points', 3,
    'teammate_win_points', 2,
    'imposter_loss_points', 5,
    'imposter_task_points', 3,
    'correct_vote_points', 2,
    'imposter_majority_alignment_bonus', 2
  ) || coalesce(p_settings, '{}'::jsonb);

  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.rooms where code = v_code);
  end loop;

  insert into public.rooms(code, created_by, settings)
  values (v_code, v_uid, v_settings) returning * into v_room;

  insert into public.players(room_id, user_id, display_name)
  values (v_room.id, v_uid, trim(p_display_name)) returning * into v_player;

  return jsonb_build_object('room_id', v_room.id, 'room_code', v_room.code,
                            'player_id', v_player.id, 'display_name', v_player.display_name);
end;
$$;

create or replace function public.join_room(p_room_code text, p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player public.players%rowtype;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if length(trim(coalesce(p_display_name,''))) < 1 or length(trim(p_display_name)) > 18 then
    raise exception 'Player name must be 1 to 18 characters';
  end if;

  select * into v_room from public.rooms
  where code = upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found'; end if;
  if v_room.status <> 'waiting' then raise exception 'This game has already started'; end if;

  if exists (select 1 from public.players where room_id = v_room.id and user_id = v_uid) then
    select * into v_player from public.players where room_id = v_room.id and user_id = v_uid;
    return jsonb_build_object('room_id', v_room.id, 'room_code', v_room.code,
                              'player_id', v_player.id, 'display_name', v_player.display_name);
  end if;

  insert into public.players(room_id, user_id, display_name)
  values (v_room.id, v_uid, trim(p_display_name)) returning * into v_player;

  return jsonb_build_object('room_id', v_room.id, 'room_code', v_room.code,
                            'player_id', v_player.id, 'display_name', v_player.display_name);
exception when unique_violation then
  raise exception 'That player name is already taken in this room';
end;
$$;

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

  select id into v_me from public.players where room_id = v_room.id and user_id = v_uid;
  if v_me is null then raise exception 'You are not a member of this room'; end if;

  select * into v_round from public.rounds where room_id = v_room.id
    order by round_number desc limit 1;

  return jsonb_build_object(
    'room_code', v_room.code,
    'room_status', v_room.status,
    'settings', v_room.settings,
    'my_player_id', v_me,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'score',p.score)
                       order by p.joined_at)
      from public.players p where p.room_id = v_room.id
    ), '[]'::jsonb),
    'current_round', case when v_round.id is null then null else
      jsonb_build_object('id',v_round.id,'round_number',v_round.round_number,'status',v_round.status) end
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
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.rooms where code = upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if not exists (select 1 from public.players where room_id=v_room.id and user_id=v_uid) then
    raise exception 'You are not a member of this room';
  end if;
  if exists (select 1 from public.rounds where room_id=v_room.id and status <> 'completed') then
    raise exception 'The previous round is not finished';
  end if;

  select count(*) into v_count from public.players where room_id=v_room.id;
  v_imposters := greatest(1, coalesce((v_room.settings->>'imposter_count')::integer,1));
  if v_count < 3 then raise exception 'At least 3 players are needed to start'; end if;
  if v_imposters >= v_count then raise exception 'There must be at least one teammate'; end if;
  if not exists (select 1 from public.tasks where active and role='teammate')
     or not exists (select 1 from public.tasks where active and role='imposter') then
    raise exception 'Task library is missing tasks for one or more roles';
  end if;

  insert into public.rounds(room_id, round_number, status)
  select v_room.id, coalesce(max(round_number),0)+1, 'playing'
  from public.rounds where room_id=v_room.id
  returning * into v_round;

  with ranked as (
    select p.id as player_id,
           row_number() over(order by random()) as rn
    from public.players p where p.room_id=v_room.id
  ), chosen as (
    select player_id, case when rn <= v_imposters then 'imposter' else 'teammate' end as role
    from ranked
  )
  insert into public.assignments(round_id, player_id, role, task_id)
  select v_round.id, c.player_id, c.role, t.id
  from chosen c
  cross join lateral (
    select id from public.tasks where active and role=c.role order by random() limit 1
  ) t;

  update public.rounds set imposter_player_id = (
    select player_id from public.assignments
    where round_id=v_round.id and role='imposter' order by random() limit 1
  ) where id=v_round.id;

  update public.rooms set status='playing' where id=v_room.id;
  return jsonb_build_object('round_id',v_round.id,'round_number',v_round.round_number);
end;
$$;

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
  select jsonb_build_object('role',a.role,'task',t.task_text,'task_completed',a.task_completed,
                            'round_status',r.status,'round_number',r.round_number)
  into v_result
  from public.assignments a
  join public.players p on p.id=a.player_id
  join public.tasks t on t.id=a.task_id
  join public.rounds r on r.id=a.round_id
  where a.round_id=p_round_id and p.user_id=v_uid;
  if v_result is null then raise exception 'No assignment found for you in this round'; end if;
  return v_result;
end;
$$;

create or replace function public.submit_round_report(p_round_id uuid, p_match_result text, p_task_completed boolean)
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
  if p_match_result not in ('win','loss') then raise exception 'Invalid match result'; end if;

  select p.id,r.room_id,r.status,r.match_result into v_player_id,v_room_id,v_status,v_existing_match_result
  from public.rounds r join public.players p on p.room_id=r.room_id
  where r.id=p_round_id and p.user_id=v_uid;
  if v_player_id is null then raise exception 'You are not in this round'; end if;
  if v_status <> 'playing' then raise exception 'This round is not accepting match reports'; end if;
  if v_existing_match_result is not null and v_existing_match_result <> p_match_result then
    raise exception 'Players must submit the same match result';
  end if;
  if v_existing_match_result is null then
    update public.rounds set match_result=p_match_result where id=p_round_id;
  end if;

  insert into public.round_reports(round_id,player_id,match_result,task_completed)
  values (p_round_id,v_player_id,p_match_result,p_task_completed)
  on conflict (round_id,player_id) do update
    set match_result=excluded.match_result,task_completed=excluded.task_completed,submitted_at=now();

  update public.assignments set task_completed=p_task_completed
  where round_id=p_round_id and player_id=v_player_id;

  select count(*) into v_total from public.players where room_id=v_room_id;
  select count(*) into v_submitted from public.round_reports where round_id=p_round_id;
  if v_submitted=v_total then
    update public.rounds set status='voting' where id=p_round_id and status='playing';
  end if;

  return jsonb_build_object('reports_received',v_submitted,'players_total',v_total,
                            'voting_open',v_submitted=v_total);
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
  select r.room_id,r.status,p.id into v_room,v_status,v_voter
  from public.rounds r
  join public.players p on p.room_id=r.room_id and p.user_id=v_uid
  where r.id=p_round_id;
  if v_voter is null then raise exception 'You are not in this round'; end if;
  if v_status <> 'voting' then raise exception 'Voting is not open yet'; end if;
  if not exists(select 1 from public.players where id=p_target_player_id and room_id=v_room) then
    raise exception 'Vote target is not in this room';
  end if;
  if p_target_player_id=v_voter then raise exception 'You cannot vote for yourself'; end if;

  insert into public.votes(round_id,voter_player_id,target_player_id)
  values(p_round_id,v_voter,p_target_player_id)
  on conflict(round_id,voter_player_id) do update set target_player_id=excluded.target_player_id,created_at=now();

  return jsonb_build_object('vote_submitted',true);
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
  select r.room_id,r.status,rm.settings into v_room_id,v_status,v_settings
  from public.rounds r join public.rooms rm on rm.id=r.room_id
  where r.id=p_round_id for update of r;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if not exists(select 1 from public.players where room_id=v_room_id and user_id=v_uid) then
    raise exception 'You are not in this room';
  end if;
  if v_status='completed' then raise exception 'This round has already been finalized'; end if;
  if v_status <> 'voting' then raise exception 'This round is not ready to finalize'; end if;

  select count(*) into v_players from public.players where room_id=v_room_id;
  select count(*) into v_votes from public.votes where round_id=p_round_id;
  if v_votes <> v_players then raise exception 'Waiting for all players to vote'; end if;

  select max(n) into v_max from (
    select count(*) n from public.votes where round_id=p_round_id group by target_player_id
  ) q;
  select count(*) into v_leaders from (
    select target_player_id,count(*) n from public.votes where round_id=p_round_id
    group by target_player_id having count(*)=v_max
  ) q;
  select target_player_id into v_majority from (
    select target_player_id,count(*) n from public.votes where round_id=p_round_id
    group by target_player_id having count(*)=v_max
  ) q limit 1;

  v_tie := v_leaders <> 1;
  select array_agg(player_id) into v_imposters from public.assignments
  where round_id=p_round_id and role='imposter';
  v_correct := not v_tie and exists(
    select 1 from public.assignments where round_id=p_round_id
    and player_id=v_majority and role='imposter'
  );

  -- Base points from each player's own report and assigned role.
  update public.players p set score = p.score +
    case when a.role='teammate' then
      (case when rr.task_completed then coalesce((v_settings->>'teammate_task_points')::integer,3) else 0 end) +
      (case when rr.match_result='win' then coalesce((v_settings->>'teammate_win_points')::integer,2) else 0 end)
    else
      (case when rr.task_completed then coalesce((v_settings->>'imposter_task_points')::integer,3) else 0 end) +
      (case when rr.match_result='loss' then coalesce((v_settings->>'imposter_loss_points')::integer,5) else 0 end)
    end
  from public.assignments a join public.round_reports rr
    on rr.round_id=a.round_id and rr.player_id=a.player_id
  where a.round_id=p_round_id and p.id=a.player_id;

  v_correct_pts := coalesce((v_settings->>'correct_vote_points')::integer,2);
  v_imp_bonus := coalesce((v_settings->>'imposter_majority_alignment_bonus')::integer,2);
  v_imp_loss := coalesce((v_settings->>'imposter_loss_points')::integer,5);

  if v_correct then
    update public.players set score=score+v_correct_pts
    where id in (select player_id from public.assignments where round_id=p_round_id and role='teammate');
    update public.players set score=score-v_imp_loss where id = any(v_imposters);
  elsif not v_tie then
    update public.players p set score=score+v_imp_bonus
    where p.id in (
      select a.player_id from public.assignments a
      join public.votes v on v.round_id=a.round_id and v.voter_player_id=a.player_id
      where a.round_id=p_round_id and a.role='imposter' and v.target_player_id=v_majority
    );
  end if;

  update public.rounds set status='completed' where id=p_round_id;
  if not exists(select 1 from public.rounds where room_id=v_room_id and status<>'completed') then
    update public.rooms set status='waiting' where id=v_room_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('player_id',p.id,'display_name',p.display_name,'score',p.score)
                            order by p.score desc), '[]'::jsonb)
  into v_changes from public.players p where p.room_id=v_room_id;

  return jsonb_build_object('tie',v_tie,'correct_vote',v_correct,
    'identified_player_id',case when v_tie then null else v_majority end,
    'imposter_player_ids',to_jsonb(v_imposters),'leaderboard',v_changes);
end;
$$;


create or replace function public.get_round_results(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_status text;
  v_imposters jsonb;
  v_leaderboard jsonb;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select room_id,status into v_room_id,v_status from public.rounds where id=p_round_id;
  if v_room_id is null then raise exception 'Round not found'; end if;
  if not exists(select 1 from public.players where room_id=v_room_id and user_id=v_uid) then
    raise exception 'You are not in this room';
  end if;
  if v_status <> 'completed' then raise exception 'Results are not available yet'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('player_id',p.id,'display_name',p.display_name)
                            order by p.display_name), '[]'::jsonb)
  into v_imposters
  from public.assignments a join public.players p on p.id=a.player_id
  where a.round_id=p_round_id and a.role='imposter';

  select coalesce(jsonb_agg(jsonb_build_object('player_id',p.id,'display_name',p.display_name,'score',p.score)
                            order by p.score desc), '[]'::jsonb)
  into v_leaderboard from public.players p where p.room_id=v_room_id;

  return jsonb_build_object('imposters',v_imposters,'leaderboard',v_leaderboard);
end;
$;

-- Only signed-in players can call these controlled functions.
revoke all on function public.create_room(text,jsonb) from public, anon;
revoke all on function public.join_room(text,text) from public, anon;
revoke all on function public.get_room_state(text) from public, anon;
revoke all on function public.start_round(text) from public, anon;
revoke all on function public.get_my_assignment(uuid) from public, anon;
revoke all on function public.submit_round_report(uuid,text,boolean) from public, anon;
revoke all on function public.submit_vote(uuid,uuid) from public, anon;
revoke all on function public.finalize_round(uuid) from public, anon;
revoke all on function public.get_round_results(uuid) from public, anon;

grant execute on function public.create_room(text,jsonb) to authenticated;
grant execute on function public.join_room(text,text) to authenticated;
grant execute on function public.get_room_state(text) to authenticated;
grant execute on function public.start_round(text) to authenticated;
grant execute on function public.get_my_assignment(uuid) to authenticated;
grant execute on function public.submit_round_report(uuid,text,boolean) to authenticated;
grant execute on function public.submit_vote(uuid,uuid) to authenticated;
grant execute on function public.finalize_round(uuid) to authenticated;
grant execute on function public.get_round_results(uuid) to authenticated;
