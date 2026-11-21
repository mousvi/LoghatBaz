-- LoghatBaz: versioned progress for the 6,000-word / 400-stage curriculum.
-- Run once in Supabase SQL Editor before enabling cloud progress sync.
-- Old level_progress rows are intentionally kept and are NOT mapped to the new curriculum.

create table if not exists public.curriculum_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  curriculum_version text not null,
  level_number integer not null check (level_number between 1 and 400),
  stars smallint not null check (stars between 1 and 3),
  xp_earned integer not null default 0 check (xp_earned >= 0),
  completed_at timestamptz not null default now(),
  primary key (user_id, curriculum_version, level_number)
);

create index if not exists curriculum_progress_user_idx
  on public.curriculum_progress (user_id, curriculum_version, completed_at desc);

alter table public.curriculum_progress enable row level security;
drop policy if exists "Users can read their curriculum progress" on public.curriculum_progress;
create policy "Users can read their curriculum progress"
  on public.curriculum_progress for select to authenticated
  using ((select auth.uid()) = user_id);

revoke insert, update, delete on public.curriculum_progress from anon, authenticated;
grant select on public.curriculum_progress to authenticated;

create or replace function public.complete_curriculum_level(
  p_curriculum_version text,
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
  if p_curriculum_version is distinct from 'loghatbaz-6000-v1' then
    raise exception 'Unknown curriculum version';
  end if;
  if p_level_number is null or p_level_number < 1 or p_level_number > 400 then
    raise exception 'Invalid level number';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 3 then
    raise exception 'Stars must be between 1 and 3';
  end if;

  if p_level_number > 50 then
    select exists (
      select 1 from public.user_entitlements e
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
    select 1 from public.curriculum_progress cp
    where cp.user_id = v_user_id
      and cp.curriculum_version = p_curriculum_version
      and cp.level_number = p_level_number - 1
  ) then
    raise exception 'Previous level is not completed';
  end if;

  v_new_xp := 40 + (p_stars * 10);
  select cp.stars, cp.xp_earned into v_existing_stars, v_old_xp
  from public.curriculum_progress cp
  where cp.user_id = v_user_id
    and cp.curriculum_version = p_curriculum_version
    and cp.level_number = p_level_number;

  if not found then
    insert into public.curriculum_progress
      (user_id, curriculum_version, level_number, stars, xp_earned)
    values
      (v_user_id, p_curriculum_version, p_level_number, p_stars, v_new_xp);
    v_delta := v_new_xp;
  else
    v_already_completed := true;
    if p_stars > v_existing_stars then
      update public.curriculum_progress
      set stars = p_stars, xp_earned = v_new_xp, completed_at = now()
      where user_id = v_user_id
        and curriculum_version = p_curriculum_version
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
  from public.profiles p where p.user_id = v_user_id;

  return jsonb_build_object(
    'curriculum_version', p_curriculum_version,
    'level_number', p_level_number,
    'stars', p_stars,
    'xp_earned', v_new_xp,
    'xp_added', v_delta,
    'total_xp', coalesce(v_total_xp, 0),
    'already_completed', v_already_completed
  );
end;
$$;

revoke all on function public.complete_curriculum_level(text, integer, integer) from public;
grant execute on function public.complete_curriculum_level(text, integer, integer) to authenticated;
