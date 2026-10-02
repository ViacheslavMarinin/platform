-- Мой маленький мир — этап 3: список игр и сохранения
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run.
-- Повторный запуск безопасен. Старая колонка profiles.data не трогается.

-- Игры платформы
create table if not exists public.apps (
  code text primary key,
  title text not null,
  path text not null,
  created_at timestamptz not null default now()
);
alter table public.apps enable row level security;
drop policy if exists "apps_read_all" on public.apps;
create policy "apps_read_all" on public.apps for select using (true);
insert into public.apps (code, title, path) values ('piko', 'Пико и сокровища', '/piko/')
  on conflict (code) do nothing;

-- Прогресс: игрок + игра → данные
create table if not exists public.saves (
  user_id uuid not null references auth.users on delete cascade,
  app text not null references public.apps (code),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, app),
  constraint saves_size check (pg_column_size(data) < 500000)
);
alter table public.saves enable row level security;
drop policy if exists "saves_select_own" on public.saves;
drop policy if exists "saves_insert_own" on public.saves;
drop policy if exists "saves_update_own" on public.saves;
create policy "saves_select_own" on public.saves for select using (auth.uid() = user_id);
create policy "saves_insert_own" on public.saves for insert with check (auth.uid() = user_id);
create policy "saves_update_own" on public.saves for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Перенос прогресса Пико из profiles.data
insert into public.saves (user_id, app, data, updated_at)
  select id, 'piko', data, updated_at from public.profiles
  where data is not null and data <> '{}'::jsonb
  on conflict (user_id, app) do nothing;

-- Проверка: сколько игроков и сохранений
select (select count(*) from public.profiles) as players,
       (select count(*) from public.saves where app = 'piko') as piko_saves;
