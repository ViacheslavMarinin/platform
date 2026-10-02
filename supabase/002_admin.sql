-- Мой маленький мир — сводка для админа (страница mlymir.ru/admin/)
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run.
-- Повторный запуск безопасен.

-- Кто админ. Список задаётся только здесь, из SQL; из игр его не изменить.
create table if not exists public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;   -- без правил: напрямую никто не читает и не пишет

insert into public.admins (user_id)
  select id from public.profiles where lower(username) = 'kover'
  on conflict do nothing;

-- Сводка. Работает с правами владельца базы, но отдаёт данные только админам.
create or replace function public.platform_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Europe/Moscow')::date;
  res jsonb;
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  with u as (
    select au.id, coalesce(p.username, au.raw_user_meta_data->>'username', '?') as username,
           (au.created_at at time zone 'Europe/Moscow') as created,
           (au.last_sign_in_at at time zone 'Europe/Moscow') as last_in
    from auth.users au left join profiles p on p.id = au.id
  ),
  s as (
    select user_id, app, (updated_at at time zone 'Europe/Moscow') as played, data from saves
  ),
  act as (   -- активность игрока: последнее сохранение или вход
    select u.id, greatest(u.last_in, (select max(played) from s where s.user_id = u.id)) as last_seen from u
  ),
  days as (
    select generate_series(today - 29, today, interval '1 day')::date as d
  )
  select jsonb_build_object(
    'generated_at', now(),
    'totals', jsonb_build_object(
      'players',    (select count(*) from u),
      'new_today',  (select count(*) from u where created::date = today),
      'new_7d',     (select count(*) from u where created::date > today - 7),
      'new_30d',    (select count(*) from u where created::date > today - 30),
      'active_today', (select count(*) from act where last_seen::date = today),
      'active_7d',    (select count(*) from act where last_seen::date > today - 7),
      'active_30d',   (select count(*) from act where last_seen::date > today - 30)
    ),
    'apps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', a.code, 'title', a.title,
        'players',   (select count(*) from s where s.app = a.code),
        'active_7d', (select count(*) from s where s.app = a.code and played::date > today - 7)
      ) order by a.created_at) from apps a), '[]'::jsonb),
    'daily', (
      select jsonb_agg(jsonb_build_object(
        'day', d,
        'new',    (select count(*) from u where created::date = d),
        'active', (select count(distinct user_id) from s where played::date = d)
      ) order by d) from days),
    'players', coalesce((
      select jsonb_agg(x order by x->>'last_seen' desc nulls last) from (
        select jsonb_build_object(
          'username', u.username,
          'created', u.created,
          'last_seen', act.last_seen,
          'games', (select coalesce(jsonb_object_agg(s.app, jsonb_build_object(
                      'played', s.played,
                      'level', case when s.app = 'piko' then s.data->>'larets-level' end)), '{}'::jsonb)
                    from s where s.user_id = u.id)
        ) as x
        from u join act on act.id = u.id
        order by act.last_seen desc nulls last
        limit 200
      ) t), '[]'::jsonb)
  ) into res;
  return res;
end $$;

revoke all on function public.platform_stats() from public, anon;
grant execute on function public.platform_stats() to authenticated;

-- Проверка: должен быть 1 админ
select count(*) as admins from public.admins;
