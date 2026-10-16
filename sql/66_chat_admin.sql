-- =====================================================================
-- sql/66_chat_admin.sql — 관리자 콘솔 '대화방' 탭용 (2026-10-16, 대화방 3단계, docs/CHAT.md)
--
--  · chat_reads(room_id, user_id, read_at) — 선생님별 '여기까지 읽음'(새 글 표시). 본인 행만.
--  · admin_chat_rooms() — 내 센터 명단 기준으로 기업방·1:1 을 모두 만들어 두고(학생이 앱을 안 열었어도 선생님이 먼저 쓸 수 있게)
--      방마다 학생 명단(이름·담당·알림 받는지), 마지막 글, 안 읽은 학생 글 수를 돌려줌.
--      '알림 받는지' = push_tokens.device_key 가 그 학생 서명토큰(make_student_token)인 기기가 있는지 — 4단계 발송도 같은 기준.
--  · admin_chat_read(p_room) — 읽음 표시.
--  · set_my_display_name(p_name) — 내 이름(학생에게 '○○ 선생님'). admin_users 는 관리자가 직접 못 고치므로 함수로 본인 행만.
--  · 권순천 계정 display_name 채움(MULTI_TEACHER.md 1단계 — 이름 칸).
--  · 멱등.
-- =====================================================================

create table if not exists public.chat_reads (
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null,
  read_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
alter table public.chat_reads enable row level security;
drop policy if exists "chat reads own" on public.chat_reads;
create policy "chat reads own" on public.chat_reads
  for all to public using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.chat_reads from anon;
grant select, insert, update, delete on public.chat_reads to authenticated;

create or replace function public.admin_chat_rooms()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;

  -- 명단 기준으로 방 만들어 두기(내 센터. super 도 자기 센터 — 다른 센터는 그 센터 관리자가)
  insert into chat_rooms (center_id, kind, company_key, company_label)
  select distinct on (_co_key(s.company)) au.center_id, 'company', _co_key(s.company), trim(s.company)
    from students s where s.center_id = au.center_id and _co_key(s.company) is not null
  on conflict (center_id, company_key) where kind = 'company' do nothing;
  insert into chat_rooms (center_id, kind, student_id, student_name)
  select au.center_id, 'direct', s.id, trim(s.name) from students s where s.center_id = au.center_id
  on conflict (center_id, student_id) where kind = 'direct' do nothing;

  with st as (
    select s.id, trim(s.name) name, s.company, _co_key(s.company) k, s.manager, s.status,
           exists (select 1 from push_tokens p where p.center_id = s.center_id and s.phone is not null
                    and p.device_key = make_student_token(s.name, s.phone)) push
      from students s where s.center_id = au.center_id
  ), rd as (
    select room_id, read_at from chat_reads where user_id = au.user_id
  )
  select coalesce(jsonb_agg(x order by (x->>'kind') = 'direct', x->>'last_at' desc nulls last, x->>'title'), '[]'::jsonb) into v
  from (
    select jsonb_build_object(
      'id', r.id, 'kind', r.kind,
      'title', case when r.kind = 'company' then r.company_label else r.student_name end,
      'company', case when r.kind = 'company' then r.company_label else (select st.company from st where st.id = r.student_id) end,
      'last_at', r.last_at,
      'members', (select coalesce(jsonb_agg(jsonb_build_object('name', st.name, 'manager', st.manager, 'push', st.push, 'status', st.status) order by st.name), '[]'::jsonb)
                    from st where (r.kind = 'company' and st.k = r.company_key) or (r.kind = 'direct' and st.id = r.student_id)),
      'last', (select jsonb_build_object('sender', m.sender, 'name', m.sender_name, 'body', left(m.body, 80), 'at', m.created_at)
                 from chat_messages m where m.room_id = r.id and not m.hidden order by m.created_at desc limit 1),
      'unread', (select count(*) from chat_messages m where m.room_id = r.id and m.sender = 'student' and not m.hidden
                   and m.created_at > coalesce((select rd.read_at from rd where rd.room_id = r.id), '-infinity'::timestamptz))
    ) x
    from chat_rooms r
    where r.center_id = au.center_id
      and (r.kind = 'company' or exists (select 1 from st where st.id = r.student_id))
  ) t;
  return jsonb_build_object('ok', true, 'me', jsonb_build_object('name', au.display_name, 'role', au.role), 'rooms', v);
end $$;

create or replace function public.admin_chat_read(p_room uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare au public.admin_users;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return; end if;
  if not exists (select 1 from chat_rooms r where r.id = p_room and (au.role = 'super_admin' or r.center_id = au.center_id)) then return; end if;
  insert into chat_reads (room_id, user_id, read_at) values (p_room, au.user_id, now())
  on conflict (room_id, user_id) do update set read_at = excluded.read_at;
end $$;

create or replace function public.set_my_display_name(p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then return jsonb_build_object('ok', false); end if;
  if v is not null and char_length(v) > 20 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  v := regexp_replace(coalesce(v, ''), '\s*선생님$', '');   -- '권순천 선생님' 으로 넣어도 이름만(글쓴이는 '이름 + 선생님')
  update admin_users set display_name = nullif(v, '') where user_id = auth.uid();
  return jsonb_build_object('ok', found, 'name', nullif(v, ''));
end $$;

revoke all on function public.admin_chat_rooms() from public, anon;
revoke all on function public.admin_chat_read(uuid) from public, anon;
revoke all on function public.set_my_display_name(text) from public, anon;
grant execute on function public.admin_chat_rooms() to authenticated, service_role;
grant execute on function public.admin_chat_read(uuid) to authenticated, service_role;
grant execute on function public.set_my_display_name(text) to authenticated, service_role;

-- 권순천 계정 이름(비어 있을 때만)
update public.admin_users au set display_name = '권순천'
  from auth.users u
 where u.id = au.user_id and lower(u.email) = 'cherry905@mju.ac.kr' and au.display_name is null;
