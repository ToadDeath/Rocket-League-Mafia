-- Allow an existing player to reconnect to their own active round.
-- New players still cannot enter after a round has started.
-- A player may leave during a round; they can rejoin with the same anonymous browser identity.

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
  v_round public.rounds%rowtype;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  if length(trim(coalesce(p_display_name,''))) < 1 or length(trim(p_display_name)) > 18 then
    raise exception 'Player name must be 1 to 18 characters';
  end if;

  select * into v_room
  from public.rooms
  where code=upper(trim(p_room_code))
  for update;
  if not found then raise exception 'Room code not found'; end if;
  if v_room.created_at < now() - interval '24 hours' then
    raise exception 'This lobby has expired';
  end if;

  select * into v_player
  from public.players
  where room_id=v_room.id and user_id=v_uid;

  select * into v_round
  from public.rounds
  where room_id=v_room.id and status in ('playing','voting')
  order by round_number desc
  limit 1;

  if found then
    -- Only a player already assigned to this round may reconnect mid-game.
    if v_player.id is null or not exists (
      select 1 from public.assignments
      where round_id=v_round.id and player_id=v_player.id
    ) then
      raise exception 'This game has already started. Only players from this round can reconnect.';
    end if;

    update public.players
    set left_at=null, last_seen_at=now(), display_name=trim(p_display_name)
    where id=v_player.id
    returning * into v_player;

    return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,
      'player_id',v_player.id,'display_name',v_player.display_name,
      'round_id',v_round.id,'round_number',v_round.round_number,'round_status',v_round.status);
  end if;

  if v_room.status <> 'waiting' then
    raise exception 'This game is not currently accepting players';
  end if;

  if v_player.id is not null then
    update public.players
    set left_at=null,last_seen_at=now(),display_name=trim(p_display_name)
    where id=v_player.id
    returning * into v_player;
  else
    insert into public.players(room_id,user_id,display_name,last_seen_at)
    values(v_room.id,v_uid,trim(p_display_name),now())
    returning * into v_player;
  end if;

  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,
    'player_id',v_player.id,'display_name',v_player.display_name);
exception when unique_violation then
  raise exception 'That player name is already taken in this room';
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
  v_player_id uuid;
begin
  if v_uid is null then raise exception 'Sign in is required'; end if;
  select * into v_room
  from public.rooms
  where code=upper(trim(p_room_code));
  if not found then return jsonb_build_object('left',true); end if;

  update public.players
  set left_at=now()
  where room_id=v_room.id and user_id=v_uid and left_at is null
  returning id into v_player_id;

  return jsonb_build_object('left',true,'player_marked_inactive',v_player_id is not null);
end;
$$;

revoke all on function public.join_room(text,text) from public, anon;
revoke all on function public.leave_room(text) from public, anon;
grant execute on function public.join_room(text,text) to authenticated;
grant execute on function public.leave_room(text) to authenticated;
