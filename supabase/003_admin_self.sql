-- Админ может узнать, что он админ (для кнопки «Сводка» на витрине). Остальные видят пустоту.
drop policy if exists "admins_select_self" on public.admins;
create policy "admins_select_self" on public.admins for select to authenticated using (user_id = auth.uid());
grant select on public.admins to authenticated;
