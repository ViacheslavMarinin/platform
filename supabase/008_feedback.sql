-- Мой маленький мир — обратная связь
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить → Run. Повторный запуск безопасен.
-- Писать может любой (и гость), читать — только админ (таблица admins) через функции ниже.

create table if not exists public.feedback (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users on delete set null,
  username text,
  contact text check (char_length(contact) <= 120),
  message text not null check (char_length(message) between 3 and 2000),
  app text,                                -- откуда написали: platform, piko, hamsters, rubezh…
  page text check (char_length(page) <= 200),
  agent text check (char_length(agent) <= 300),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists feedback_created_idx on public.feedback (created_at desc);
alter table public.feedback enable row level security;   -- правил нет: напрямую никто не читает и не пишет

-- Отправить сообщение (гость или игрок). Ограничения от спама: 5 сообщений в час с аккаунта,
-- 30 в час от всех гостей вместе.
create or replace function public.send_feedback(p_message text, p_contact text default null, p_app text default null, p_page text default null, p_agent text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  uname text;
  msg text := trim(coalesce(p_message, ''));
  fid bigint;
begin
  if char_length(msg) < 3 then
    raise exception 'too short' using errcode = '22023';
  end if;
  if char_length(msg) > 2000 then
    raise exception 'too long' using errcode = '22023';
  end if;
  if uid is not null then
    if (select count(*) from feedback where user_id = uid and created_at > now() - interval '1 hour') >= 5 then
      raise exception 'rate limit' using errcode = 'P0001';
    end if;
    select username into uname from profiles where id = uid;
  else
    if (select count(*) from feedback where user_id is null and created_at > now() - interval '1 hour') >= 30 then
      raise exception 'rate limit' using errcode = 'P0001';
    end if;
  end if;
  insert into feedback (user_id, username, contact, message, app, page, agent)
  values (uid, uname, nullif(left(trim(coalesce(p_contact, '')), 120), ''), msg,
          left(nullif(trim(coalesce(p_app, '')), ''), 40), left(p_page, 200), left(p_agent, 300))
  returning id into fid;
  return jsonb_build_object('id', fid);
end $$;
revoke all on function public.send_feedback(text, text, text, text, text) from public;
grant execute on function public.send_feedback(text, text, text, text, text) to anon, authenticated;

-- Список сообщений — только админу
create or replace function public.feedback_list(p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'unread', (select count(*) from feedback where not is_read),
    'total',  (select count(*) from feedback),
    'items', coalesce((select jsonb_agg(to_jsonb(f) - 'user_id' order by f.created_at desc) from (
      select * from feedback order by created_at desc limit greatest(1, least(coalesce(p_limit, 200), 1000))
    ) f), '[]'::jsonb)
  );
end $$;
revoke all on function public.feedback_list(integer) from public, anon;
grant execute on function public.feedback_list(integer) to authenticated;

-- Отметить прочитанным / непрочитанным — только админу
create or replace function public.feedback_mark(p_id bigint, p_read boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update feedback set is_read = coalesce(p_read, true) where id = p_id;
end $$;
revoke all on function public.feedback_mark(bigint, boolean) from public, anon;
grant execute on function public.feedback_mark(bigint, boolean) to authenticated;

-- Сколько непрочитанных — для значка на кнопке «Сводка» (остальным — 0)
create or replace function public.feedback_unread()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when exists (select 1 from admins where user_id = auth.uid())
              then (select count(*)::int from feedback where not is_read) else 0 end
$$;
revoke all on function public.feedback_unread() from public, anon;
grant execute on function public.feedback_unread() to authenticated;

-- Проверка
select count(*) as feedback_messages from public.feedback;
