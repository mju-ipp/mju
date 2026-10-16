-- =====================================================================
-- sql/65_chat_rooms.sql — 대화방: 기업방(그 기업 학생 여럿 + 센터 선생님) · 1:1(학생 한 명 + 센터 선생님) (2026-10-16)
--
-- 사용자 결정(10/16): 기업방은 단톡방처럼 서로 글이 다 보임, 기업 HRD 담당자는 들어오지 않음(센터 선생님만),
--   선생님 글만 푸시(4단계, push-sender) — 학생 글은 푸시 없음. 1:1 도 같은 표로.
--
--  · chat_rooms     — kind 'company'(company_key = 정규화한 기업명) / 'direct'(student_id). 센터 스코프.
--  · chat_messages  — sender 'student' / 'teacher'. 선생님 글은 push_state 'pending' → 발송기가 'sent'.
--  · admin_users.display_name — 선생님 이름(글쓴이 표시·'내 담당' 거르기). 이름은 서버가 붙임(클라 미신뢰).
--  · 학생 RPC(본인 확인 = 코드 또는 서명토큰, 소속 기업 = 명단 students.company — 클라가 보낸 기업명은 안 씀):
--      my_chats(p_code, p_token)                       → 내 방 목록(기업방·1:1, 없으면 만듦)
--      my_chat_messages(p_code, p_token, p_room)       → 그 방 글(최근 200, 숨김 제외)
--      post_chat_message(p_code, p_token, p_room, p_text)
--    호출 제한: 본인 확인 '실패'만 IP 당 10분 30회(코드 맞히기 막기) — 같은 회사 와이파이·통신사 공용 IP 학생들이
--    방을 열 때마다 걸리지 않게. 글쓰기는 학생당 10분 20개.
--  · 관리자: 표 직접 접근(센터 스코프 RLS) + admin_post_chat(p_room, p_text) 로 글쓰기(이름·센터 서버가 확인).
--  · anon 은 표 직접 접근 없음(RPC 만) → rls-check MUST_BE_BLOCKED 에 chat_rooms·chat_messages.
--  · 멱등: if not exists / create or replace / drop policy if exists.
-- =====================================================================

alter table public.admin_users add column if not exists display_name text;

create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  kind text not null check (kind in ('company', 'direct')),
  company_key text,          -- kind=company: 정규화한 기업명(㈜·(주)·주식회사·공백 제거, 소문자)
  company_label text,        -- 보여줄 기업명(명단 표기)
  student_id uuid,           -- kind=direct: students.id
  student_name text,         -- kind=direct: 보여줄 이름
  created_at timestamptz not null default now(),
  last_at timestamptz,       -- 마지막 글 시각(목록 정렬)
  check ((kind = 'company' and company_key is not null and student_id is null)
      or (kind = 'direct' and student_id is not null and company_key is null))
);
create unique index if not exists chat_rooms_company_uniq on public.chat_rooms (center_id, company_key) where kind = 'company';
create unique index if not exists chat_rooms_direct_uniq on public.chat_rooms (center_id, student_id) where kind = 'direct';

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  center_id uuid not null references public.centers(id),
  sender text not null check (sender in ('student', 'teacher')),
  sender_name text not null,
  student_id uuid,           -- sender=student
  admin_user_id uuid,        -- sender=teacher
  body text not null check (char_length(body) between 1 and 2000),
  hidden boolean not null default false,   -- 선생님이 숨긴 글(학생에겐 안 보임)
  push_state text check (push_state in ('pending', 'sent', 'none')),   -- 선생님 글만 'pending'
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_room_at on public.chat_messages (room_id, created_at);
create index if not exists chat_messages_push on public.chat_messages (push_state) where push_state = 'pending';

alter table public.chat_rooms enable row level security;
alter table public.chat_messages enable row level security;

-- 관리자만 직접 접근(센터 스코프). to public + 헬퍼 패턴(sql/62 와 같음)
drop policy if exists "chat rooms admin all" on public.chat_rooms;
create policy "chat rooms admin all" on public.chat_rooms
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "chat messages admin all" on public.chat_messages;
create policy "chat messages admin all" on public.chat_messages
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());

revoke all on public.chat_rooms from anon;
revoke all on public.chat_messages from anon;
grant select, insert, update, delete on public.chat_rooms to authenticated;
grant select, insert, update, delete on public.chat_messages to authenticated;

-- 기업명 정규화(sql/18 my_company_info 와 같은 규칙)
create or replace function public._co_key(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(replace(replace(replace(replace(lower(coalesce(p, '')), '㈜', ''), '(주)', ''), '주식회사', ''), ' ', ''), '')
$$;

-- 본인 확인: 코드 또는 서명토큰 → 명단 학생 한 명(같은 이름 여러 기수면 진행중 → 최근 기수). 실패하면 IP 실패 횟수 +1
create or replace function public._chat_me(p_code text, p_token text)
returns public.students
language plpgsql security definer set search_path = public as $$
declare v_name text; v_center uuid; st public.students; ip text;
begin
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where s.phone is not null and make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_name is not null then
    select * into st from students s
     where s.center_id = v_center and replace(trim(s.name), ' ', '') = replace(trim(v_name), ' ', '')
     order by (s.status = '진행중') desc nulls last, s.cohort desc nulls last
     limit 1;
  end if;
  if st.id is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin
      perform check_verify_rate('chatfail:' || ip);
    exception when undefined_function then null;
    end;
  end if;
  return st;
end $$;
revoke all on function public._chat_me(text, text) from public, anon, authenticated;

-- 내 방(기업방은 명단 기업이 있을 때만) — 없으면 만들고 돌려줌
create or replace function public._chat_my_rooms(st public.students)
returns setof public.chat_rooms
language plpgsql security definer set search_path = public as $$
declare k text := _co_key(st.company);
begin
  if k is not null then
    insert into chat_rooms (center_id, kind, company_key, company_label)
    values (st.center_id, 'company', k, trim(st.company))
    on conflict (center_id, company_key) where kind = 'company' do nothing;
  end if;
  insert into chat_rooms (center_id, kind, student_id, student_name)
  values (st.center_id, 'direct', st.id, trim(st.name))
  on conflict (center_id, student_id) where kind = 'direct' do nothing;
  return query
    select r.* from chat_rooms r
     where r.center_id = st.center_id
       and ((r.kind = 'company' and r.company_key = k) or (r.kind = 'direct' and r.student_id = st.id));
end $$;
revoke all on function public._chat_my_rooms(public.students) from public, anon, authenticated;

create or replace function public.my_chats(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v jsonb;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind,
           'title', case when r.kind = 'company' then r.company_label else '센터 선생님' end,
           'last_at', r.last_at,
           'last', (select jsonb_build_object('sender', m.sender, 'name', m.sender_name, 'body', left(m.body, 80), 'at', m.created_at)
                      from chat_messages m where m.room_id = r.id and not m.hidden order by m.created_at desc limit 1))
           order by (r.kind = 'company') desc), '[]'::jsonb)
    into v from _chat_my_rooms(st) r;
  return jsonb_build_object('ok', true, 'me', jsonb_build_object('name', st.name, 'company', st.company), 'rooms', v);
end $$;

create or replace function public.my_chat_messages(p_code text default null, p_token text default null, p_room uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v jsonb;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  if not exists (select 1 from _chat_my_rooms(st) r where r.id = p_room) then
    return jsonb_build_object('ok', false, 'reason', 'room');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'sender', x.sender, 'name', x.sender_name, 'body', x.body, 'at', x.created_at,
           'mine', x.sender = 'student' and x.student_id = st.id) order by x.created_at), '[]'::jsonb)
    into v
    from (select * from chat_messages m where m.room_id = p_room and not m.hidden
           order by m.created_at desc limit 200) x;
  return jsonb_build_object('ok', true, 'messages', v);
end $$;

create or replace function public.post_chat_message(p_code text default null, p_token text default null, p_room uuid default null, p_text text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v_body text := btrim(coalesce(p_text, '')); v_id uuid; v_at timestamptz;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  if v_body = '' or char_length(v_body) > 2000 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  if not exists (select 1 from _chat_my_rooms(st) r where r.id = p_room) then
    return jsonb_build_object('ok', false, 'reason', 'room');
  end if;
  if (select count(*) from chat_messages m where m.student_id = st.id and m.sender = 'student'
        and m.created_at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  insert into chat_messages (room_id, center_id, sender, sender_name, student_id, body, push_state)
  values (p_room, st.center_id, 'student', trim(st.name), st.id, v_body, 'none')
  returning id, created_at into v_id, v_at;
  update chat_rooms set last_at = v_at where id = p_room;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at);
end $$;

-- 관리자 글쓰기 — 이름(display_name)·센터는 서버가 admin_users 에서. 다른 센터 방이면 거부(super 는 허용)
create or replace function public.admin_post_chat(p_room uuid, p_text text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; r public.chat_rooms; v_body text := btrim(coalesce(p_text, '')); v_id uuid; v_at timestamptz;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into r from chat_rooms where id = p_room;
  if r.id is null or (au.role <> 'super_admin' and r.center_id is distinct from au.center_id) then
    return jsonb_build_object('ok', false, 'reason', 'room');
  end if;
  if v_body = '' or char_length(v_body) > 2000 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  insert into chat_messages (room_id, center_id, sender, sender_name, admin_user_id, body, push_state)
  values (r.id, r.center_id, 'teacher', coalesce(nullif(trim(au.display_name), ''), '센터') || ' 선생님', au.user_id, v_body, 'pending')
  returning id, created_at into v_id, v_at;
  update chat_rooms set last_at = v_at where id = r.id;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at);
end $$;

revoke all on function public.my_chats(text, text) from public;
revoke all on function public.my_chat_messages(text, text, uuid) from public;
revoke all on function public.post_chat_message(text, text, uuid, text) from public;
revoke all on function public.admin_post_chat(uuid, text) from public, anon;
grant execute on function public.my_chats(text, text) to anon, authenticated, service_role;
grant execute on function public.my_chat_messages(text, text, uuid) to anon, authenticated, service_role;
grant execute on function public.post_chat_message(text, text, uuid, text) to anon, authenticated, service_role;
grant execute on function public.admin_post_chat(uuid, text) to authenticated, service_role;
