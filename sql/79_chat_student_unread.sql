-- 79. 학생 대화방 안 읽은 글 수 (2026-10-23 사용자: 하단 '대화방' 탭에 카톡처럼 숫자)
-- 재실행해도 안전(create table if not exists / create or replace).
--
--  · chat_student_reads(room_id, student_id, read_at) — 학생별 '여기까지 읽음'. 학생은 비로그인이라 표 직접 접근 없음(RPC 만).
--  · my_chat_messages — 방을 열면(글을 받아 가면) 그 방 read_at = now(). 별도 '읽음' 호출 없이 '열어 봄 = 읽음'.
--  · my_chats — 방마다 'unread' 추가(목록에 방별 숫자).
--  · my_chat_unread(p_code, p_token) → {ok, total} — 모든 학생 페이지 하단 탭 숫자용 가벼운 조회.
--  안 읽은 글 = 숨기지 않은 글 중 내가 쓴 것 빼고(선생님 글 + 같은 기업방 다른 학생 글) read_at 이후.
--  읽음 기록이 없는 방은 처음부터 전부 셈(카톡과 같음). 10/23 기준 운영 글 4건뿐이라 기준일을 따로 두지 않음.

create table if not exists public.chat_student_reads (
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (room_id, student_id)
);
alter table public.chat_student_reads enable row level security;
revoke all on public.chat_student_reads from anon, authenticated;
-- 정책 없음 = anon·관리자 직접 접근 0. SECURITY DEFINER 함수만 읽고 씀.

create or replace function public._chat_unread(st public.students, p_room uuid)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from chat_messages m
   where m.room_id = p_room and not m.hidden
     and not (m.sender = 'student' and m.student_id = st.id)
     and m.created_at > coalesce((select r.read_at from chat_student_reads r where r.room_id = p_room and r.student_id = st.id), '-infinity'::timestamptz)
$$;
revoke all on function public._chat_unread(public.students, uuid) from public, anon, authenticated;

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
           'unread', _chat_unread(st, r.id),
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
  insert into chat_student_reads (room_id, student_id, read_at) values (p_room, st.id, now())
  on conflict (room_id, student_id) do update set read_at = excluded.read_at;
  return jsonb_build_object('ok', true, 'messages', v);
end $$;

create or replace function public.my_chat_unread(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; n int;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  select coalesce(sum(_chat_unread(st, r.id)), 0)::int into n from _chat_my_rooms(st) r;
  return jsonb_build_object('ok', true, 'total', n);
end $$;

revoke all on function public.my_chat_unread(text, text) from public;
grant execute on function public.my_chats(text, text) to anon, authenticated, service_role;
grant execute on function public.my_chat_messages(text, text, uuid) to anon, authenticated, service_role;
grant execute on function public.my_chat_unread(text, text) to anon, authenticated, service_role;
