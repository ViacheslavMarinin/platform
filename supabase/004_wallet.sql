-- Мой маленький мир — кошелёк: уточки, журнал операций, балансы, приветственный подарок
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run.
-- Повторный запуск безопасен. Актуальная версия функций — в 005_exchange.sql.

-- Валюты: уточки (общая) и, позже, валюты игр
create table if not exists public.currencies (
  code text primary key,
  title text not null,
  app text references public.apps (code),          -- null = общая валюта платформы
  created_at timestamptz not null default now()
);
alter table public.currencies enable row level security;
drop policy if exists "currencies_read_all" on public.currencies;
create policy "currencies_read_all" on public.currencies for select using (true);
insert into public.currencies (code, title) values ('duck', 'Уточки') on conflict (code) do nothing;

-- Журнал: только дописывается. Каждое начисление и списание — строка.
create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  currency text not null references public.currencies (code),
  amount integer not null check (amount <> 0),
  reason text not null,                              -- 'once:…' — разовая награда, второй раз не начислится
  app text references public.apps (code),
  created_at timestamptz not null default now()
);
create index if not exists ledger_user_idx on public.ledger (user_id, created_at desc);
create unique index if not exists ledger_once_idx on public.ledger (user_id, reason) where reason like 'once:%';
alter table public.ledger enable row level security;
drop policy if exists "ledger_select_own" on public.ledger;
create policy "ledger_select_own" on public.ledger for select to authenticated using (user_id = auth.uid());

-- Балансы: сумма журнала, в минус уйти нельзя
create table if not exists public.balances (
  user_id uuid not null references auth.users on delete cascade,
  currency text not null references public.currencies (code),
  amount bigint not null default 0 check (amount >= 0),
  primary key (user_id, currency)
);
alter table public.balances enable row level security;
drop policy if exists "balances_select_own" on public.balances;
create policy "balances_select_own" on public.balances for select to authenticated using (user_id = auth.uid());

-- Внутренняя операция: запись в журнал + баланс одним шагом. Из игр не вызывается.
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

-- Кошелёк игрока. При первом обращении дарит 100 уточек (один раз на аккаунт).
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
      gift := 0;   -- подарок уже выдан параллельным запросом
    end;
  end if;
  return jsonb_build_object(
    'balances', coalesce((select jsonb_object_agg(currency, amount) from balances where user_id = uid), '{}'::jsonb),
    'welcome', gift
  );
end $$;
revoke all on function public.wallet() from public, anon;
grant execute on function public.wallet() to authenticated;

-- Проверка
select (select count(*) from public.currencies) as currencies,
       (select count(*) from public.ledger where reason = 'once:welcome') as gifts_given;
