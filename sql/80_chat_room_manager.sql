-- 80. 대화방 담당 선생님 (2026-10-23 사용자: "선생님별 담당 기업 — 지금은 내가 디폴트로 되어 있잖아", 이름은 "항상 담당 선생님 이름")
-- 재실행해도 안전(create or replace).
--
--  · _chat_room_manager(room) — 방의 담당 선생님 = 명단 students.manager.
--      1:1 = 그 학생의 담당, 기업방 = 그 기업 학생들의 담당(여럿이면 진행중 학생이 많은 쪽). 10/23 기준 기업마다 담당 1명.
--  · admin_post_chat — 선생님 글 이름(sender_name)을 '쓴 사람'이 아니라 '그 방 담당 선생님'으로. 담당이 없으면 쓴 사람 이름.
--      실제 쓴 사람은 admin_user_id 에 그대로 남음(감사용). 권순천 계정 하나로 다른 선생님 담당 기업에 대신 써도 학생에겐 담당 이름.
--  · admin_chat_rooms — 방마다 'manager' 추가(콘솔 선생님별 보기·'학생에게 ○○ 선생님으로 보여요').
--  · my_chats — 1:1 방 이름 '센터 선생님' → '○○ 선생님'(담당), 방마다 'teacher' 추가.
--  기존 선생님 글 6건은 모두 권순천 담당 기업방이라 이름을 고칠 글이 없음(10/23 확인).

create or replace function public._chat_room_manager(r public.chat_rooms)
returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(s.manager), '') from students s
   where s.center_id = r.center_id and nullif(trim(s.manager), '') is not null
     and ((r.kind = 'company' and _co_key(s.company) = r.company_key) or (r.kind = 'direct' and s.id = r.student_id))
   group by trim(s.manager)
   order by count(*) filter (where s.status = '진행중') desc, count(*) desc, trim(s.manager)
   limit 1
$$;
revoke all on function public._chat_room_manager(public.chat_rooms) from public, anon, authenticated;

create or replace function public.admin_post_chat(p_room uuid, p_text text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; r public.chat_rooms; v_body text := btrim(coalesce(p_text, '')); v_id uuid; v_at timestamptz; v_name text;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into r from chat_rooms where id = p_room;
  if r.id is null or (au.role <> 'super_admin' and r.center_id is distinct from au.center_id) then
    return jsonb_build_object('ok', false, 'reason', 'room');
  end if;
  if v_body = '' or char_length(v_body) > 2000 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  v_name := coalesce(_chat_room_manager(r), nullif(trim(au.display_name), ''), '센터') || ' 선생님';
  insert into chat_messages (room_id, center_id, sender, sender_name, admin_user_id, body, push_state)
  values (r.id, r.center_id, 'teacher', v_name, au.user_id, v_body, 'pending')
  returning id, created_at into v_id, v_at;
  update chat_rooms set last_at = v_at where id = r.id;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at, 'name', v_name);
end $$;

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
      'manager', _chat_room_manager(r),
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

create or replace function public.my_chats(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v jsonb;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind,
           'title', case when r.kind = 'company' then r.company_label else coalesce(_chat_room_manager(r), '센터') || ' 선생님' end,
           'teacher', _chat_room_manager(r),
           'last_at', r.last_at,
           'unread', _chat_unread(st, r.id),
           'last', (select jsonb_build_object('sender', m.sender, 'name', m.sender_name, 'body', left(m.body, 80), 'at', m.created_at)
                      from chat_messages m where m.room_id = r.id and not m.hidden order by m.created_at desc limit 1))
           order by (r.kind = 'company') desc), '[]'::jsonb)
    into v from _chat_my_rooms(st) r;
  return jsonb_build_object('ok', true, 'me', jsonb_build_object('name', st.name, 'company', st.company), 'rooms', v);
end $$;

grant execute on function public.admin_post_chat(uuid, text) to authenticated, service_role;
grant execute on function public.admin_chat_rooms() to authenticated, service_role;
grant execute on function public.my_chats(text, text) to anon, authenticated, service_role;
