-- Rocket League Mafia: inactivity-based room expiry and scheduled cleanup.
-- Run this once in Supabase SQL Editor after presence-migration.sql.

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
  if not exists (
    select 1 from public.players p
    where p.room_id = v_room.id
      and p.last_seen_at >= now() - interval '24 hours'
  ) then raise exception 'This lobby has expired. Create a new one.'; end if;

  update public.players
  set last_seen_at=now()
  where room_id=v_room.id and user_id=v_uid and left_at is null
  returning id into v_player_id;
  if v_player_id is null then raise exception 'You are not an active member of this lobby'; end if;
  return jsonb_build_object('ok',true);
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
  if not exists (
    select 1 from public.players p
    where p.room_id = v_room.id
      and p.last_seen_at >= now() - interval '24 hours'
  ) then raise exception 'This lobby has expired. Create a new one.'; end if;
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
  if not exists (
    select 1 from public.players p
    where p.room_id = v_room.id
      and p.last_seen_at >= now() - interval '24 hours'
  ) then raise exception 'This lobby has expired. Create a new one.'; end if;

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

create or replace function public.cleanup_inactive_rooms()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_room_id uuid;
  v_deleted_rooms integer := 0;
begin
  -- A room is eligible only when no player has checked in during the last 24 hours.
  for v_room_id in
    select r.id
    from public.rooms r
    where not exists (
      select 1
      from public.players p
      where p.room_id = r.id
        and p.last_seen_at >= now() - interval '24 hours'
    )
  loop
    -- rounds owns the round reports, assignments and votes via cascading foreign keys.
    delete from public.rounds where room_id = v_room_id;
    delete from public.players where room_id = v_room_id;
    delete from public.rooms where id = v_room_id;
    v_deleted_rooms := v_deleted_rooms + 1;
  end loop;

  return v_deleted_rooms;
end;
$$;

revoke all on function public.cleanup_inactive_rooms() from public, anon, authenticated;

-- Supabase Cron runs this cleanup once per hour.
create extension if not exists pg_cron;

select cron.schedule(
  'rlm-cleanup-inactive-rooms',
  '17 * * * *',
  'select public.cleanup_inactive_rooms();'
);
