-- Мой маленький мир — обмен уточек на монеты игр, подарок 100 уточек, выдача уточек админом
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run.
-- Нужны таблицы из 004_wallet.sql (этот скрипт создаёт их сам, если их ещё нет). Повторный запуск безопасен.

-- ---------- таблицы кошелька (если 004 ещё не запускали) ----------
create table if not exists public.currencies (
  code text primary key,
  title text not null,
  app text references public.apps (code),
  created_at timestamptz not null default now()
);
alter table public.currencies enable row level security;
drop policy if exists "currencies_read_all" on public.currencies;
create policy "currencies_read_all" on public.currencies for select using (true);

create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  currency text not null references public.currencies (code),
  amount integer not null check (amount <> 0),
  reason text not null,
  app text references public.apps (code),
  created_at timestamptz not null default now()
);
create index if not exists ledger_user_idx on public.ledger (user_id, created_at desc);
create unique index if not exists ledger_once_idx on public.ledger (user_id, reason) where reason like 'once:%';
alter table public.ledger enable row level security;
drop policy if exists "ledger_select_own" on public.ledger;
create policy "ledger_select_own" on public.ledger for select to authenticated using (user_id = auth.uid());

create table if not exists public.balances (
  user_id uuid not null references auth.users on delete cascade,
  currency text not null references public.currencies (code),
  amount bigint not null default 0 check (amount >= 0),
  primary key (user_id, currency)
);
alter table public.balances enable row level security;
drop policy if exists "balances_select_own" on public.balances;
create policy "balances_select_own" on public.balances for select to authenticated using (user_id = auth.uid());

create or replace function public.ledger_add(p_user uuid, p_currency text, p_amount integer, p_reason text, p_app text default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare bal bigint;
begin
  if p_amount < 0 then
    -- списание: строка баланса блокируется до конца операции, в минус уйти нельзя
    update balances set amount = amount + p_amount
      where user_id = p_user and currency = p_currency and amount + p_amount >= 0
      returning amount into bal;
    if not found then
      raise exception 'not enough' using errcode = '23514';   -- check_violation
    end if;
  else
    insert into balances (user_id, currency, amount) values (p_user, p_currency, p_amount)
      on conflict (user_id, currency) do update set amount = balances.amount + excluded.amount
      returning amount into bal;
  end if;
  insert into ledger (user_id, currency, amount, reason, app) values (p_user, p_currency, p_amount, p_reason, p_app);
  return bal;
end $$;
revoke all on function public.ledger_add(uuid, text, integer, text, text) from public, anon, authenticated;

-- ---------- валюты игр и курс ----------
alter table public.currencies add column if not exists per_duck integer check (per_duck > 0);   -- сколько монет игры за 1 уточку
insert into public.apps (code, title, path) values ('hamsters', 'Хомячья мозаика', '/hamsters/') on conflict (code) do nothing;
insert into public.currencies (code, title) values ('duck', 'Уточки') on conflict (code) do nothing;
insert into public.currencies (code, title, app, per_duck) values
  ('piko:coin', 'Монеты Пико', 'piko', 10),
  ('hamsters:coin', 'Монеты Хомячьей мозаики', 'hamsters', 10)
on conflict (code) do update set per_duck = excluded.per_duck;

-- ---------- кошелёк: подарок новым игрокам — 100 уточек ----------
create or replace function public.wallet()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  gift integer := 0;
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if not exists (select 1 from ledger where user_id = uid and reason = 'once:welcome') then
    begin
      perform ledger_add(uid, 'duck', 100, 'once:welcome');
      gift := 100;
    exception when unique_violation then
      gift := 0;
    end;
  end if;
  return jsonb_build_object(
    'balances', coalesce((select jsonb_object_agg(currency, amount) from balances where user_id = uid and currency = 'duck'), '{}'::jsonb),
    'welcome', gift
  );
end $$;
revoke all on function public.wallet() from public, anon;
grant execute on function public.wallet() to authenticated;

-- ---------- обмен уточек на монеты игры (только в одну сторону) ----------
create or replace function public.exchange(p_app text, p_ducks integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cur record;
  coins integer;
  tx bigint;
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_ducks is null or p_ducks < 1 or p_ducks > 100000 then
    raise exception 'bad amount' using errcode = '22023';
  end if;
  select code, per_duck into cur from currencies where app = p_app and per_duck is not null limit 1;
  if not found then
    raise exception 'no exchange for this game' using errcode = '22023';
  end if;
  coins := p_ducks * cur.per_duck;
  begin
    perform ledger_add(uid, 'duck', -p_ducks, 'exchange', p_app);
  exception when check_violation then
    raise exception 'not enough ducks' using errcode = 'P0001';
  end;
  insert into ledger (user_id, currency, amount, reason, app) values (uid, cur.code, coins, 'exchange', p_app) returning id into tx;
  insert into balances (user_id, currency, amount) values (uid, cur.code, coins)
    on conflict (user_id, currency) do update set amount = balances.amount + excluded.amount;
  return jsonb_build_object(
    'id', tx, 'ducks', p_ducks, 'coins', coins,
    'balances', coalesce((select jsonb_object_agg(currency, amount) from balances where user_id = uid and currency = 'duck'), '{}'::jsonb)
  );
end $$;
revoke all on function public.exchange(text, integer) from public, anon;
grant execute on function public.exchange(text, integer) to authenticated;

-- ---------- подарок уточек от админа ----------
create or replace function public.admin_grant(p_username text, p_ducks integer, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
  bal bigint;
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_ducks is null or p_ducks = 0 or abs(p_ducks) > 1000000 then
    raise exception 'bad amount' using errcode = '22023';
  end if;
  select id into target from profiles where lower(username) = lower(trim(p_username));
  if target is null then
    raise exception 'no such player' using errcode = 'P0002';
  end if;
  begin
    bal := ledger_add(target, 'duck', p_ducks, 'gift:' || coalesce(nullif(trim(p_note), ''), 'от админа'));
  exception when check_violation then
    raise exception 'not enough ducks' using errcode = 'P0001';
  end;
  return jsonb_build_object('username', p_username, 'ducks', p_ducks, 'balance', bal);
end $$;
revoke all on function public.admin_grant(text, integer, text) from public, anon;
grant execute on function public.admin_grant(text, integer, text) to authenticated;

-- ---------- сводка для админа: теперь с уточками ----------
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
      'active_30d',   (select count(*) from act where last_seen::date > today - 30),
      'ducks_total',  (select coalesce(sum(amount), 0) from balances where currency = 'duck'),
      'ducks_gifted', (select coalesce(sum(amount), 0) from ledger where currency = 'duck' and amount > 0),
      'ducks_spent',  (select coalesce(-sum(amount), 0) from ledger where currency = 'duck' and amount < 0)
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
          'ducks', coalesce((select amount from balances b where b.user_id = u.id and b.currency = 'duck'), 0),
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

-- Проверка: курс обмена
select code, title, per_duck from public.currencies order by code;
