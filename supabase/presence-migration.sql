-- Rocket League Mafia: lobby presence and expiry migration
-- Run once in Supabase SQL Editor after the existing secure-game-functions.sql.

alter table public.players
  add column if not exists last_seen_at timestamptz not null default now(),
  add column if not exists left_at timestamptz;

create or replace function public.heartbeat_room(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player_id uuid;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.rooms where code=upper(trim(p_room_code));
  if not found then raise exception 'Room not found'; end if;
  if v_room.created_at < now() - interval '24 hours' then
    raise exception 'This lobby has expired. Create a new one.';
  end if;

  update public.players
  set last_seen_at=now()
  where room_id=v_room.id and user_id=v_uid and left_at is null
  returning id into v_player_id;
  if v_player_id is null then raise exception 'You are not an active member of this lobby'; end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.leave_room(p_room_code text)
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
  select * into v_room from public.rooms where code=upper(trim(p_room_code));
  if not found then return jsonb_build_object('left',true); end if;
  if v_room.status <> 'waiting' then
    raise exception 'You cannot leave while a round is in progress';
  end if;
  update public.players set left_at=now()
  where room_id=v_room.id and user_id=v_uid and left_at is null;
  return jsonb_build_object('left',true);
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
  where code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found'; end if;
  if v_room.created_at < now() - interval '24 hours' then raise exception 'This lobby has expired'; end if;
  if v_room.status <> 'waiting' then raise exception 'This game has already started'; end if;

  select * into v_player from public.players
  where room_id=v_room.id and user_id=v_uid;
  if found then
    if v_player.left_at is not null then
      update public.players set left_at=null,last_seen_at=now(),display_name=trim(p_display_name)
      where id=v_player.id returning * into v_player;
    else
      update public.players set last_seen_at=now()
      where id=v_player.id returning * into v_player;
    end if;
    return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,
      'player_id',v_player.id,'display_name',v_player.display_name);
  end if;

  insert into public.players(room_id,user_id,display_name,last_seen_at)
  values(v_room.id,v_uid,trim(p_display_name),now()) returning * into v_player;
  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,
    'player_id',v_player.id,'display_name',v_player.display_name);
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
  select * into v_room from public.rooms where code=upper(trim(p_room_code));
  if not found then raise exception 'Room not found'; end if;
  if v_room.created_at < now() - interval '24 hours' then raise exception 'This lobby has expired'; end if;

  update public.players set last_seen_at=now()
  where room_id=v_room.id and user_id=v_uid and left_at is null
  returning id into v_me;
  if v_me is null then raise exception 'You are not an active member of this lobby'; end if;

  select * into v_round from public.rounds where room_id=v_room.id
    order by round_number desc limit 1;

  return jsonb_build_object(
    'room_code',v_room.code,'room_status',v_room.status,'settings',v_room.settings,
    'my_player_id',v_me,
    'players',coalesce((
      select jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'score',p.score)
                       order by p.joined_at)
      from public.players p
      where p.room_id=v_room.id and p.left_at is null and p.last_seen_at > now()-interval '90 seconds'
    ),'[]'::jsonb),
    'current_round',case when v_round.id is null then null else
      jsonb_build_object('id',v_round.id,'round_number',v_round.round_number,'status',v_round.status) end
  );
end;
$$;

revoke all on function public.heartbeat_room(text) from public, anon;
revoke all on function public.leave_room(text) from public, anon;
grant execute on function public.heartbeat_room(text) to authenticated;
grant execute on function public.leave_room(text) to authenticated;
