-- LughatBaz: Supabase schema for accounts and cloud progress
-- Run this file once in Supabase Dashboard -> SQL Editor.
-- Safe to re-run: objects use IF NOT EXISTS / DROP TRIGGER IF EXISTS.

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  total_xp integer not null default 0 check (total_xp >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.level_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  level_number integer not null check (level_number between 1 and 400),
  stars smallint not null check (stars between 1 and 3),
  xp_earned integer not null default 0 check (xp_earned >= 0),
  completed_at timestamptz not null default now(),
  primary key (user_id, level_number)
);

-- Paid access is granted only by a trusted payment webhook / server process.
-- Never allow normal users to insert or edit their own entitlements.
create table if not exists public.user_entitlements (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  tier text not null check (tier in ('pack50', 'full')),
  status text not null default 'active' check (status in ('active', 'revoked', 'expired')),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists level_progress_user_completed_idx
  on public.level_progress (user_id, completed_at desc);
create index if not exists user_entitlements_user_status_idx
  on public.user_entitlements (user_id, status);

alter table public.profiles enable row level security;
alter table public.level_progress enable row level security;
alter table public.user_entitlements enable row level security;

drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own display name" on public.profiles;
create policy "Users can update their own display name"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can read their own progress" on public.level_progress;
create policy "Users can read their own progress"
  on public.level_progress for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can read their own entitlements" on public.user_entitlements;
create policy "Users can read their own entitlements"
  on public.user_entitlements for select to authenticated
  using ((select auth.uid()) = user_id);

-- Restrict profile writes so a client cannot award itself XP.
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;

-- Create a profile automatically after email / OAuth signup.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', '')
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- The app calls this RPC after a stage is completed.
-- XP is calculated on the database, not trusted from the phone.
-- Stages 1-50 are free. Stages 51-100 require pack50/full;
-- stages 101-400 require full. A stage can only be completed
-- after the previous stage has been completed.
create or replace function public.complete_level(
  p_level_number integer,
  p_stars integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing_stars integer;
  v_old_xp integer := 0;
  v_new_xp integer;
  v_delta integer := 0;
  v_already_completed boolean := false;
  v_total_xp integer;
  v_has_access boolean := false;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_level_number is null or p_level_number < 1 or p_level_number > 400 then
    raise exception 'Invalid level number';
  end if;

  if p_stars is null or p_stars < 1 or p_stars > 3 then
    raise exception 'Stars must be between 1 and 3';
  end if;

  if p_level_number > 50 then
    select exists (
      select 1
      from public.user_entitlements e
      where e.user_id = v_user_id
        and e.status = 'active'
        and (e.expires_at is null or e.expires_at > now())
        and (
          (p_level_number between 51 and 100 and e.tier in ('pack50', 'full'))
          or (p_level_number between 101 and 400 and e.tier = 'full')
        )
    ) into v_has_access;

    if not v_has_access then
      raise exception 'Purchase required for this level';
    end if;
  end if;

  if p_level_number > 1 and not exists (
    select 1 from public.level_progress lp
    where lp.user_id = v_user_id
      and lp.level_number = p_level_number - 1
  ) then
    raise exception 'Previous level is not completed';
  end if;

  -- Fixed server-side XP prevents a modified client from awarding arbitrary XP.
  v_new_xp := 40 + (p_stars * 10);

  select lp.stars, lp.xp_earned
    into v_existing_stars, v_old_xp
  from public.level_progress lp
  where lp.user_id = v_user_id
    and lp.level_number = p_level_number;

  if not found then
    insert into public.level_progress (user_id, level_number, stars, xp_earned)
    values (v_user_id, p_level_number, p_stars, v_new_xp);
    v_delta := v_new_xp;
  else
    v_already_completed := true;
    if p_stars > v_existing_stars then
      update public.level_progress
      set stars = p_stars,
          xp_earned = v_new_xp,
          completed_at = now()
      where user_id = v_user_id
        and level_number = p_level_number;
      v_delta := greatest(v_new_xp - v_old_xp, 0);
    end if;
  end if;

  insert into public.profiles (user_id, total_xp)
  values (v_user_id, v_delta)
  on conflict (user_id) do update
    set total_xp = public.profiles.total_xp + v_delta,
        updated_at = now();

  select p.total_xp into v_total_xp
  from public.profiles p
  where p.user_id = v_user_id;

  return jsonb_build_object(
    'level_number', p_level_number,
    'stars', p_stars,
    'xp_earned', v_new_xp,
    'xp_added', v_delta,
    'total_xp', coalesce(v_total_xp, 0),
    'already_completed', v_already_completed
  );
end;
$$;

revoke all on function public.complete_level(integer, integer) from public;
grant execute on function public.complete_level(integer, integer) to authenticated;

-- Users may read their own rows; progress and entitlement writes happen
-- only through the protected RPC / trusted server-side payment process.
