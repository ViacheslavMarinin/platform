-- Мой маленький мир — «Последний рубеж»: регистрация игры, чтобы звёзды сохранялись в облаке
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run. Повторный запуск безопасен.
insert into public.apps (code, title, path) values ('rubezh', 'Последний рубеж', '/rubezh/')
  on conflict (code) do nothing;
select code, title, path from public.apps order by created_at;
