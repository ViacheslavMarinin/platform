-- Мой маленький мир — монеты «Последнего рубежа» за уточки (курс как у всех игр: 1 уточка = 10 монет)
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run. Нужен 006_rubezh.sql. Повторный запуск безопасен.
insert into public.apps (code, title, path) values ('rubezh', 'Последний рубеж', '/rubezh/') on conflict (code) do nothing;
insert into public.currencies (code, title, app, per_duck) values ('rubezh:coin', 'Монеты Последнего рубежа', 'rubezh', 10)
  on conflict (code) do update set per_duck = excluded.per_duck;
select code, app, per_duck from public.currencies order by code;
